require "./spec_helper"

private def v2(payload)
  payload.merge({v: 2}).to_json
end

private def expect_success_v2(response : String) : JSON::Any
  parsed = parse_response(response)
  parsed["protocol_version"].as_i.should eq(2)
  parsed["success"].as_bool.should be_true
  parsed["error_code"].raw.should be_nil
  parsed
end

private def expect_error_v2(response : String, code : String) : JSON::Any
  parsed = parse_response(response)
  parsed["protocol_version"].as_i.should eq(2)
  parsed["success"].as_bool.should be_false
  parsed["error_code"].as_s.should eq(code)
  parsed
end

describe Karma::Idempotency do
  it "deduplicates repeated batch_add commands by idempotency key" do
    cluster = Karma::Cluster.new
    request = v2({
      op:              "series.batch_add",
      series:          "usage",
      items:           [[101_u64, 20260529_u64, 5_u64]],
      idempotency_key: "event-123",
    })

    first = expect_success_v2(Karma::Commands.call(request, cluster))
    repeat = expect_success_v2(Karma::Commands.call(request, cluster))
    sum = expect_success_v2(Karma::Commands.call(v2({op: "counter.sum", series: "usage", key: 101_u64}), cluster))

    first["idempotent"].as_bool.should be_false
    repeat["idempotent"].as_bool.should be_true
    sum["response"].as_i.should eq(5)
  end

  it "deduplicates repeated increment commands by idempotency key" do
    cluster = Karma::Cluster.new
    request = v2({
      op:              "counter.increment",
      series:          "usage",
      key:             101_u64,
      bucket:          20260529_u64,
      value:           2_u64,
      idempotency_key: "event-124",
    })

    expect_success_v2(Karma::Commands.call(request, cluster))
    repeat = expect_success_v2(Karma::Commands.call(request, cluster))
    sum = expect_success_v2(Karma::Commands.call(v2({op: "counter.sum", series: "usage", key: 101_u64}), cluster))

    repeat["idempotent"].as_bool.should be_true
    sum["response"].as_i.should eq(2)
  end

  it "rejects the same idempotency key with a different payload" do
    cluster = Karma::Cluster.new
    base = {
      op:              "series.batch_add",
      series:          "usage",
      idempotency_key: "event-conflict",
    }

    expect_success_v2(Karma::Commands.call(v2(base.merge({items: [[101_u64, 20260529_u64, 5_u64]]})), cluster))
    conflict = expect_error_v2(Karma::Commands.call(v2(base.merge({items: [[101_u64, 20260529_u64, 6_u64]]})), cluster), "idempotency_conflict")
    sum = expect_success_v2(Karma::Commands.call(v2({op: "counter.sum", series: "usage", key: 101_u64}), cluster))

    conflict["response"].as_s.should contain("Idempotency key")
    sum["response"].as_i.should eq(5)
  end

  it "preserves idempotency through WAL replay" do
    cluster = Karma::Cluster.new
    request = v2({
      op:              "series.batch_add",
      series:          "usage",
      items:           [[101_u64, 20260529_u64, 5_u64]],
      idempotency_key: "event-wal",
    })

    expect_success_v2(Karma::Commands.call(request, cluster))

    restored = Karma::Cluster.restore_with_wal(Karma.config.dump_dir)
    repeat = expect_success_v2(Karma::Commands.call(request, restored))
    sum = expect_success_v2(Karma::Commands.call(v2({op: "counter.sum", series: "usage", key: 101_u64}), restored))

    repeat["idempotent"].as_bool.should be_true
    sum["response"].as_i.should eq(5)
  end

  it "preserves prune semantics during late WAL replay" do
    dump_dir = Karma.config.dump_dir
    Dir.mkdir_p(dump_dir)
    request = {
      v:               2,
      op:              "series.batch_add",
      series:          "usage",
      items:           [[101_u64, 20260529_u64, 5_u64]],
      idempotency_key: "event-pruned-wal",
    }
    entries = [
      {
        v:     2,
        lsn:   1_u64,
        entry: request.merge({idempotency_created_at_unix: 10_i64}),
      },
      {
        v:     2,
        lsn:   2_u64,
        entry: {v: 2, op: "idempotency.prune", before: 11_i64},
      },
    ]
    File.write(Karma::Wal.path(dump_dir), entries.map(&.to_json).join("\n") + "\n")

    restored = Karma::Cluster.restore_with_wal(dump_dir)
    repeat = expect_success_v2(Karma::Commands.call(request.to_json, restored))
    sum = expect_success_v2(Karma::Commands.call(v2({op: "counter.sum", series: "usage", key: 101_u64}), restored))

    repeat["idempotent"].as_bool.should be_false
    sum["response"].as_i.should eq(10)
  end

  it "preserves idempotency through snapshot restore after WAL truncation" do
    cluster = Karma::Cluster.new
    request = v2({
      op:              "series.batch_add",
      series:          "usage",
      items:           [[101_u64, 20260529_u64, 5_u64]],
      idempotency_key: "event-snapshot",
    })

    expect_success_v2(Karma::Commands.call(request, cluster))
    expect_success_v2(Karma::Commands.call(v2({op: "snapshot.create_all"}), cluster))

    restored = Karma::Cluster.restore_with_wal(Karma.config.dump_dir)
    repeat = expect_success_v2(Karma::Commands.call(request, restored))
    sum = expect_success_v2(Karma::Commands.call(v2({op: "counter.sum", series: "usage", key: 101_u64}), restored))

    repeat["idempotent"].as_bool.should be_true
    sum["response"].as_i.should eq(5)
  end

  it "keeps ingest streams committed after commit and skips repeated chunks" do
    cluster = Karma::Cluster.new
    begin_request = v2({op: "ingest.begin", stream_id: "import-42", mode: "add", granularity: "day"})
    chunk_request = v2({
      op:        "ingest.chunk",
      stream_id: "import-42",
      series:    "usage",
      chunk_seq: 1_u64,
      items:     [[101_u64, 20260529_u64, 5_u64]],
    })
    commit_request = v2({op: "ingest.commit", stream_id: "import-42"})

    expect_success_v2(Karma::Commands.call(begin_request, cluster))
    expect_success_v2(Karma::Commands.call(chunk_request, cluster))
    expect_success_v2(Karma::Commands.call(commit_request, cluster))
    repeat_commit = expect_success_v2(Karma::Commands.call(commit_request, cluster))
    repeat_begin = expect_success_v2(Karma::Commands.call(begin_request, cluster))
    repeat_chunk = expect_success_v2(Karma::Commands.call(chunk_request, cluster))
    sum = expect_success_v2(Karma::Commands.call(v2({op: "counter.sum", series: "usage", key: 101_u64}), cluster))

    repeat_commit["response"]["status"].as_s.should eq("already_committed")
    repeat_begin["response"]["status"].as_s.should eq("already_committed")
    repeat_chunk["response"]["skipped"].as_bool.should be_true
    repeat_chunk["response"]["committed"].as_bool.should be_true
    sum["response"].as_i.should eq(5)
  end

  it "rejects conflicting chunks after ingest commit" do
    cluster = Karma::Cluster.new

    expect_success_v2(Karma::Commands.call(v2({op: "ingest.begin", stream_id: "import-conflict", mode: "add"}), cluster))
    expect_success_v2(Karma::Commands.call(v2({
      op:        "ingest.chunk",
      stream_id: "import-conflict",
      series:    "usage",
      chunk_seq: 1_u64,
      items:     [[101_u64, 20260529_u64, 5_u64]],
    }), cluster))
    expect_success_v2(Karma::Commands.call(v2({op: "ingest.commit", stream_id: "import-conflict"}), cluster))

    conflict = expect_error_v2(Karma::Commands.call(v2({
      op:        "ingest.chunk",
      stream_id: "import-conflict",
      series:    "usage",
      chunk_seq: 1_u64,
      items:     [[101_u64, 20260529_u64, 6_u64]],
    }), cluster), "idempotency_conflict")

    conflict["response"].as_s.should contain("committed")
  end

  it "prunes old records and ends the deduplication guarantee" do
    cluster = Karma::Cluster.new
    request = v2({
      op:              "series.batch_add",
      series:          "usage",
      items:           [[101_u64, 20260529_u64, 5_u64]],
      idempotency_key: "event-prune",
    })

    expect_success_v2(Karma::Commands.call(request, cluster))
    prune = expect_success_v2(Karma::Commands.call(v2({
      op:     "idempotency.prune",
      before: (Time.utc + 1.day).to_rfc3339,
      limit:  10,
    }), cluster))
    expect_success_v2(Karma::Commands.call(request, cluster))
    sum = expect_success_v2(Karma::Commands.call(v2({op: "counter.sum", series: "usage", key: 101_u64}), cluster))

    prune["response"]["deleted"].as_i.should eq(1)
    sum["response"].as_i.should eq(10)
  end

  it "reports idempotency stats and metrics" do
    cluster = Karma::Cluster.new
    request = v2({
      op:              "counter.increment",
      series:          "usage",
      key:             101_u64,
      bucket:          20260529_u64,
      value:           1_u64,
      idempotency_key: "event-metrics",
    })

    expect_success_v2(Karma::Commands.call(request, cluster))
    expect_success_v2(Karma::Commands.call(request, cluster))
    expect_error_v2(Karma::Commands.call(v2({
      op:              "counter.increment",
      series:          "usage",
      key:             101_u64,
      bucket:          20260529_u64,
      value:           2_u64,
      idempotency_key: "event-metrics",
    }), cluster), "idempotency_conflict")

    stats = expect_success_v2(Karma::Commands.call(v2({op: "system.stats"}), cluster))
    metrics = expect_success_v2(Karma::Commands.call(v2({op: "system.metrics"}), cluster))["response"].as_s

    stats["response"]["idempotency_record_count"].as_i.should eq(1)
    stats["response"]["idempotency_hits"].as_i.should eq(1)
    stats["response"]["idempotency_conflicts"].as_i.should eq(1)
    metrics.should contain("karma_idempotency_records 1")
    metrics.should contain("karma_idempotency_hits_total 1")
  end
end
