require "./spec_helper"

describe "operations commands" do
  it "returns health response" do
    cluster = Karma::Cluster.new

    parsed = expect_success(Karma::Commands.call({v: 2, op: "system.health"}.to_json, cluster))

    parsed["response"]["status"].as_s.should eq("ok")
    parsed["response"]["role"].as_s.should eq("master")
    parsed["response"]["wal_enabled"].as_bool.should be_true
  end

  it "returns stats response" do
    dump_dir = File.expand_path(".spec_stats_#{Time.local.to_unix_ms}")
    Karma.configure { |c| c.dump_dir = dump_dir }
    cluster = Karma::Cluster.new

    Karma::Commands.call({v: 2, op: "counter.increment", series: "articles", key: 42_u64}.to_json, cluster)

    parsed = expect_success(Karma::Commands.call({v: 2, op: "system.stats"}.to_json, cluster))

    parsed["response"]["trees"].as_i.should eq(1)
    parsed["response"]["keys"].as_i.should eq(1)
    parsed["response"]["role"].as_s.should eq("master")
    parsed["response"]["wal_bytes"].as_i.should be > 0
    parsed["response"]["wal_current_lsn"].as_i.should be > 0
    parsed["response"]["memory_bytes"].as_i.should be > 0
    parsed["response"]["command_count"].as_i.should be > 0
    parsed["response"]["latency_ms_last"].as_f.should be >= 0.0
    parsed["response"]["query_timeout_count"].as_i.should be >= 0
    parsed["response"]["batch_read_count"].as_i.should be >= 0
    parsed["response"]["batch_write_count"].as_i.should be >= 0
    parsed["response"]["retention_count"].as_i.should be >= 0
    parsed["response"]["compact_count"].as_i.should be >= 0
    parsed["response"]["ingest_active_streams"].as_i.should eq(0)
  end

  it "returns metrics response" do
    cluster = Karma::Cluster.new

    parsed = expect_success(Karma::Commands.call({v: 2, op: "system.metrics"}.to_json, cluster))

    metrics = parsed["response"].as_s
    metrics.should contain("karma_uptime_seconds")
    metrics.should contain("karma_trees")
    metrics.should contain("karma_role")
    metrics.should contain("karma_wal_current_lsn")
    metrics.should contain("karma_memory_bytes")
    metrics.should contain("karma_commands_total")
    metrics.should contain("karma_errors_total")
    metrics.should contain("karma_query_timeouts_total")
    metrics.should contain("karma_batch_reads_total")
    metrics.should contain("karma_batch_read_keys_total")
    metrics.should contain("karma_batch_writes_total")
    metrics.should contain("karma_batch_write_items_total")
    metrics.should contain("karma_retention_operations_total")
    metrics.should contain("karma_compactions_total")
    metrics.should contain("karma_command_latency_ms")
    metrics.should contain("karma_ingest_active_streams")
    metrics.should contain("karma_ingest_chunks_applied_total")
  end

  it "returns batch, retention, compaction, and timeout metrics" do
    cluster = Karma::Cluster.new

    Karma::Commands.call({
      v:      2,
      op:     "series.batch_add",
      series: "links",
      items:  [[42_u64, 20260501_u64, 2_u64], [43_u64, 20260502_u64, 3_u64]],
    }.to_json, cluster)
    Karma::Commands.call({v: 2, op: "counter.batch_sum", series: "links", keys: [42_u64, 43_u64]}.to_json, cluster)
    Karma::Commands.call({v: 2, op: "series.delete_before", series: "links", before: 20260502_u64}.to_json, cluster)
    Karma::Commands.call({v: 2, op: "series.compact", series: "links"}.to_json, cluster)

    Karma.configure { |c| c.query_timeout_ms = 1 }
    cluster.pick("large") do |tree|
      50_000.times do |index|
        tree.increment((index + 1).to_u64, 20260505_u64, 1_u64)
      end
    end
    Karma::Commands.call({v: 2, op: "tree.summary", tree: "large"}.to_json, cluster)
    Karma.configure { |c| c.query_timeout_ms = 1_000 }

    stats = expect_success(Karma::Commands.call({v: 2, op: "system.stats"}.to_json, cluster))["response"]
    stats["batch_read_count"].as_i.should be >= 1
    stats["batch_read_key_count"].as_i.should be >= 2
    stats["batch_write_count"].as_i.should be >= 1
    stats["batch_write_item_count"].as_i.should be >= 2
    stats["retention_count"].as_i.should be >= 1
    stats["compact_count"].as_i.should be >= 1
    stats["query_timeout_count"].as_i.should be >= 1

    metrics = expect_success(Karma::Commands.call({v: 2, op: "system.metrics"}.to_json, cluster))["response"].as_s
    metrics.should contain("karma_batch_reads_total")
    metrics.should contain("karma_batch_writes_total")
    metrics.should contain("karma_retention_operations_total")
    metrics.should contain("karma_compactions_total")
    metrics.should contain("karma_query_timeouts_total")
  ensure
    Karma.configure { |c| c.query_timeout_ms = 1_000 }
  end

  it "returns ingest stats and metrics" do
    cluster = Karma::Cluster.new

    Karma::Commands.call({v: 2, op: "ingest.begin", mode: "add", stream_id: "metrics-stream"}.to_json, cluster)
    chunk = {
      v:         2,
      op:        "ingest.chunk",
      stream_id: "metrics-stream",
      series:    "links",
      chunk_seq: 1_u64,
      items:     [[42_u64, 20260505_u64, 10_u64]],
    }.to_json
    Karma::Commands.call(chunk, cluster)
    Karma::Commands.call(chunk, cluster)
    Karma::Commands.call({
      v:         2,
      op:        "ingest.chunk",
      stream_id: "metrics-stream",
      series:    "links",
      chunk_seq: 3_u64,
      items:     [[43_u64, 20260505_u64, 10_u64]],
    }.to_json, cluster)

    stats = expect_success(Karma::Commands.call({v: 2, op: "system.stats"}.to_json, cluster))["response"]
    stats["ingest_active_streams"].as_i.should eq(1)
    stats["ingest_chunks_applied"].as_i.should eq(1)
    stats["ingest_chunks_skipped"].as_i.should eq(1)
    stats["ingest_chunks_rejected"].as_i.should eq(1)
    stats["ingest_items_applied"].as_i.should eq(1)
    stats["ingest_latency_ms_last"].as_f.should be >= 0.0

    metrics = expect_success(Karma::Commands.call({v: 2, op: "system.metrics"}.to_json, cluster))["response"].as_s
    metrics.should contain("karma_ingest_active_streams 1")
    metrics.should contain("karma_ingest_chunks_applied_total 1")
    metrics.should contain("karma_ingest_chunks_skipped_total 1")
    metrics.should contain("karma_ingest_chunks_rejected_total 1")
    metrics.should contain("karma_ingest_items_applied_total 1")
  end

  it "records reconciliation report stats and metrics" do
    cluster = Karma::Cluster.new

    parsed = parse_response(Karma::Commands.call({
      v:              2,
      op:             "reconciliation.report",
      checked_points: 3_i64,
      mismatch_count: 1_i64,
      absolute_drift: 7_i64,
      max_abs_delta:  5_i64,
    }.to_json, cluster))
    parsed["protocol_version"].as_i.should eq(2)
    parsed["success"].as_bool.should be_true
    parsed["response"].as_s.should eq("OK")

    stats = expect_success(Karma::Commands.call({v: 2, op: "system.stats"}.to_json, cluster))["response"]
    stats["reconciliation_run_count"].as_i.should be >= 1
    stats["reconciliation_checked_points"].as_i.should be >= 3
    stats["reconciliation_mismatch_count"].as_i.should be >= 1
    stats["reconciliation_absolute_drift"].as_i.should be >= 7
    stats["reconciliation_last_run_unix"].as_i.should be > 0
    stats["reconciliation_last_checked_points"].as_i.should eq(3)
    stats["reconciliation_last_mismatch_count"].as_i.should eq(1)
    stats["reconciliation_last_absolute_drift"].as_i.should eq(7)
    stats["reconciliation_last_max_abs_delta"].as_i.should eq(5)
    stats["recovery_checkpoint_count"].as_i.should be >= 0
    stats["recovery_last_checkpoint_unix"].as_i.should be >= 0

    metrics = expect_success(Karma::Commands.call({v: 2, op: "system.metrics"}.to_json, cluster))["response"].as_s
    metrics.should contain("karma_reconciliation_runs_total")
    metrics.should contain("karma_reconciliation_checked_points_total")
    metrics.should contain("karma_reconciliation_mismatches_total")
    metrics.should contain("karma_reconciliation_last_max_abs_delta 5")
    metrics.should contain("karma_recovery_checkpoints")
    metrics.should contain("karma_recovery_last_checkpoint_unix")
  end

  it "rejects invalid reconciliation reports" do
    cluster = Karma::Cluster.new

    response = Karma::Commands.call({
      v:              2,
      op:             "reconciliation.report",
      checked_points: 1_i64,
      mismatch_count: 2_i64,
    }.to_json, cluster)

    parsed = parse_response(response)
    parsed["protocol_version"].as_i.should eq(2)
    parsed["success"].as_bool.should be_false
    parsed["error_code"].as_s.should eq("validation_error")
  end

  it "returns replication status" do
    dump_dir = File.expand_path(".spec_replication_status_#{Time.local.to_unix_ms}")
    Karma.configure { |c| c.dump_dir = dump_dir }
    cluster = Karma::Cluster.new

    Karma::Commands.call({v: 2, op: "counter.increment", tree: "articles", key: 42_u64}.to_json, cluster)
    cluster.dump_all
    Karma::Recovery.checkpoint("clickhouse-links", "export-2026-05-05", "batch-42", dump_dir)

    parsed = parse_response(Karma::Commands.call({v: 2, op: "replication.status"}.to_json, cluster))
    status = parsed["response"]

    parsed["protocol_version"].as_i.should eq(2)
    parsed["success"].as_bool.should be_true
    status["role"].as_s.should eq("master")
    status["wal_enabled"].as_bool.should be_true
    status["wal_current_lsn"].as_i.should be > 0
    status["last_snapshot_lsn"].as_i.should be > 0
    status["replication_poll_attempt_count"].as_i.should eq(0)
    status["replication_poll_error_count"].as_i.should eq(0)
    status["replication_bootstrap_attempt_count"].as_i.should eq(0)
    status["replication_bootstrap_error_count"].as_i.should eq(0)
    status["latest_snapshots"].as_a.first["tree"].as_s.should eq("articles")
    status["recovery"]["checkpoint_count"].as_i.should eq(1)
    status["recovery"]["checkpoints"].as_a.first["source"].as_s.should eq("clickhouse-links")
  end

  it "allows read-only token to inspect replication status" do
    Karma.configure do |c|
      c.auth_token = "write-secret"
      c.read_auth_token = "read-secret"
    end
    cluster = Karma::Cluster.new

    parsed = parse_response(Karma::Commands.call({
      v:     2,
      op:    "replication.status",
      token: "read-secret",
    }.to_json, cluster))

    parsed["success"].as_bool.should be_true
    parsed["response"]["role"].as_s.should eq("master")
  ensure
    Karma.configure do |c|
      c.auth_token = nil
      c.read_auth_token = nil
    end
  end

  it "returns replication entries after LSN" do
    dump_dir = File.expand_path(".spec_replication_entries_#{Time.local.to_unix_ms}")
    Karma.configure { |c| c.dump_dir = dump_dir }
    cluster = Karma::Cluster.new

    Karma::Commands.call({v: 2, op: "counter.increment", tree: "articles", key: 41_u64}.to_json, cluster)
    Karma::Commands.call({v: 2, op: "counter.increment", tree: "articles", key: 42_u64}.to_json, cluster)
    Karma::Commands.call({v: 2, op: "counter.increment", tree: "articles", key: 43_u64}.to_json, cluster)

    parsed = parse_response(Karma::Commands.call({
      v:         2,
      op:        "replication.entries",
      after_lsn: 1_u64,
      limit:     2,
    }.to_json, cluster))
    response = parsed["response"]

    parsed["protocol_version"].as_i.should eq(2)
    parsed["success"].as_bool.should be_true
    response["after_lsn"].as_i.should eq(1)
    response["limit"].as_i.should eq(2)
    response["byte_limit"].as_i.should be > 0
    response["entries_bytes"].as_i.should be > 0
    response["truncated_by_bytes"].as_bool.should be_false
    response["count"].as_i.should eq(2)
    response["source_lsn"].as_i.should eq(3)
    response["next_lsn"].as_i.should eq(3)
    response["entries"].as_a.map { |entry| entry["lsn"].as_i }.should eq([2, 3])
    response["entries"].as_a.first["entry"]["key"].as_i.should eq(42)
  end

  it "limits replication entries by response byte budget" do
    dump_dir = File.expand_path(".spec_replication_entries_budget_#{Time.local.to_unix_ms}")
    Karma.configure do |c|
      c.dump_dir = dump_dir
      c.max_response_bytes = 2_400
    end
    cluster = Karma::Cluster.new

    10.times do |index|
      Karma::Commands.call({v: 2, op: "counter.increment", tree: "articles", key: (index + 1).to_u64}.to_json, cluster)
    end

    parsed = parse_response(Karma::Commands.call({
      v:         2,
      op:        "replication.entries",
      after_lsn: 0_u64,
      limit:     10,
    }.to_json, cluster))
    response = parsed["response"]

    parsed["success"].as_bool.should be_true
    response["count"].as_i.should be < 10
    response["count"].as_i.should be > 0
    response["truncated_by_bytes"].as_bool.should be_true
    response["next_lsn"].as_i.should eq(response["entries"].as_a.last["lsn"].as_i)
  ensure
    Karma.configure { |c| c.max_response_bytes = 1_048_576 }
  end

  it "reports replication gap when requested WAL was compacted by snapshot" do
    dump_dir = File.expand_path(".spec_replication_entries_compacted_#{Time.local.to_unix_ms}")
    Karma.configure { |c| c.dump_dir = dump_dir }
    cluster = Karma::Cluster.new

    Karma::Commands.call({v: 2, op: "counter.increment", tree: "articles", key: 41_u64}.to_json, cluster)
    Karma::Commands.call({v: 2, op: "counter.increment", tree: "articles", key: 42_u64}.to_json, cluster)
    cluster.dump_all

    compacted = parse_response(Karma::Commands.call({
      v:         2,
      op:        "replication.entries",
      after_lsn: 0_u64,
    }.to_json, cluster))
    compacted["success"].as_bool.should be_false
    compacted["error_code"].as_s.should eq("replication_gap")

    current = parse_response(Karma::Commands.call({
      v:         2,
      op:        "replication.entries",
      after_lsn: 2_u64,
    }.to_json, cluster))
    current["success"].as_bool.should be_true
    current["response"]["count"].as_i.should eq(0)
    current["response"]["source_lsn"].as_i.should eq(2)
  end

  it "allows read-only token to read replication entries" do
    dump_dir = File.expand_path(".spec_replication_entries_auth_#{Time.local.to_unix_ms}")
    Karma.configure do |c|
      c.dump_dir = dump_dir
      c.auth_token = "write-secret"
      c.read_auth_token = "read-secret"
    end
    cluster = Karma::Cluster.new

    Karma::Commands.call({v: 2, op: "counter.increment", tree: "articles", key: 42_u64, token: "write-secret"}.to_json, cluster)

    parsed = parse_response(Karma::Commands.call({
      v:         2,
      op:        "replication.entries",
      after_lsn: 0_u64,
      token:     "read-secret",
    }.to_json, cluster))

    parsed["success"].as_bool.should be_true
    parsed["response"]["count"].as_i.should eq(1)
  ensure
    Karma.configure do |c|
      c.auth_token = nil
      c.read_auth_token = nil
    end
  end

  it "validates replication entries request" do
    cluster = Karma::Cluster.new

    missing = parse_response(Karma::Commands.call({v: 2, op: "replication.entries"}.to_json, cluster))
    missing["success"].as_bool.should be_false
    missing["error_code"].as_s.should eq("validation_error")

    bad_limit = parse_response(Karma::Commands.call({v: 2, op: "replication.entries", after_lsn: 0_u64, limit: 0}.to_json, cluster))
    bad_limit["success"].as_bool.should be_false
    bad_limit["error_code"].as_s.should eq("validation_error")

    bad_lsn = parse_response(Karma::Commands.call({v: 2, op: "replication.entries", after_lsn: -1, limit: 1}.to_json, cluster))
    bad_lsn["success"].as_bool.should be_false
    bad_lsn["error_code"].as_s.should eq("validation_error")
  end

  it "verifies restorable dumps" do
    dump_dir = File.expand_path(".spec_verify_#{Time.local.to_unix_ms}")
    Karma.configure { |c| c.dump_dir = dump_dir }
    cluster = Karma::Cluster.new

    Karma::Commands.call({v: 2, op: "counter.increment", series: "articles", key: 42_u64}.to_json, cluster)
    cluster.dump_all

    parsed = expect_success(Karma::Commands.call({v: 2, op: "snapshot.verify"}.to_json, cluster))

    parsed["response"]["status"].as_s.should eq("ok")
    parsed["response"]["trees"].as_i.should eq(1)
    parsed["response"]["keys"].as_i.should eq(1)
    parsed["response"]["snapshot_metadata_checked"].as_i.should eq(1)
    parsed["response"]["restore_snapshot_lsn"].as_i.should be > 0
    parsed["response"]["wal_entries_checked"].as_i.should eq(0)
    parsed["response"]["wal_lsn_file"].as_i.should be > 0
  end

  it "rejects invalid snapshot metadata during verify" do
    dump_dir = File.expand_path(".spec_verify_metadata_#{Time.local.to_unix_ms}")
    Karma.configure { |c| c.dump_dir = dump_dir }
    cluster = Karma::Cluster.new

    Karma::Commands.call({v: 2, op: "counter.increment", series: "articles", key: 42_u64}.to_json, cluster)
    cluster.dump_all
    dump_path = Karma::Backup.dumps(dump_dir).first
    metadata_path = Karma::Backup.metadata_path(dump_path)
    metadata = JSON.parse(File.read(metadata_path)).as_h
    metadata["bytes"] = JSON::Any.new(0_i64)
    File.write(metadata_path, metadata.to_json)

    parsed = parse_response(Karma::Commands.call({v: 2, op: "snapshot.verify"}.to_json, cluster))

    parsed["success"].as_bool.should be_false
    parsed["error_code"].as_s.should eq("validation_error")
    parsed["response"].as_s.should contain("Snapshot metadata bytes mismatch")
  end

  it "rejects WAL gaps during verify" do
    dump_dir = File.expand_path(".spec_verify_wal_gap_#{Time.local.to_unix_ms}")
    Karma.configure { |c| c.dump_dir = dump_dir }
    cluster = Karma::Cluster.new

    Karma::Commands.call({v: 2, op: "counter.increment", tree: "articles", key: 41_u64}.to_json, cluster)
    Karma::Commands.call({v: 2, op: "counter.increment", tree: "articles", key: 42_u64}.to_json, cluster)
    Karma::Commands.call({v: 2, op: "counter.increment", tree: "articles", key: 43_u64}.to_json, cluster)
    lines = File.read_lines(Karma::Wal.path(dump_dir))
    File.write(Karma::Wal.path(dump_dir), "#{lines[0]}\n#{lines[2]}\n")

    parsed = parse_response(Karma::Commands.call({v: 2, op: "snapshot.verify"}.to_json, cluster))

    parsed["success"].as_bool.should be_false
    parsed["error_code"].as_s.should eq("validation_error")
    parsed["response"].as_s.should contain("WAL LSN gap")
  end

  it "rejects WAL entries already covered by snapshot metadata during verify" do
    dump_dir = File.expand_path(".spec_verify_wal_covered_#{Time.local.to_unix_ms}")
    Karma.configure { |c| c.dump_dir = dump_dir }
    cluster = Karma::Cluster.new

    Karma::Commands.call({v: 2, op: "counter.increment", series: "articles", key: 42_u64}.to_json, cluster)
    Karma::Commands.call({v: 2, op: "snapshot.create", series: "articles"}.to_json, cluster)

    parsed = parse_response(Karma::Commands.call({v: 2, op: "snapshot.verify"}.to_json, cluster))

    parsed["success"].as_bool.should be_false
    parsed["error_code"].as_s.should eq("validation_error")
    parsed["response"].as_s.should contain("already covered by snapshot")
  end

  it "rejects inconsistent latest snapshot LSNs during verify" do
    dump_dir = File.expand_path(".spec_verify_snapshot_lsn_mismatch_#{Time.local.to_unix_ms}")
    Karma.configure { |c| c.dump_dir = dump_dir }
    cluster = Karma::Cluster.new

    Karma::Commands.call({v: 2, op: "counter.increment", series: "articles", key: 41_u64}.to_json, cluster)
    Karma::Commands.call({v: 2, op: "counter.increment", series: "links", key: 42_u64}.to_json, cluster)
    Karma::Commands.call({v: 2, op: "snapshot.create", series: "articles"}.to_json, cluster)
    Karma::Commands.call({v: 2, op: "counter.increment", series: "links", key: 43_u64}.to_json, cluster)
    Karma::Commands.call({v: 2, op: "snapshot.create", series: "links"}.to_json, cluster)

    parsed = parse_response(Karma::Commands.call({v: 2, op: "snapshot.verify"}.to_json, cluster))

    parsed["success"].as_bool.should be_false
    parsed["error_code"].as_s.should eq("validation_error")
    parsed["response"].as_s.should contain("inconsistent last_lsn")
  end

  it "returns snapshot info" do
    dump_dir = File.expand_path(".spec_snapshot_info_#{Time.local.to_unix_ms}")
    Karma.configure { |c| c.dump_dir = dump_dir }
    cluster = Karma::Cluster.new

    Karma::Commands.call({v: 2, op: "counter.increment", series: "articles", key: 42_u64}.to_json, cluster)
    cluster.dump_all

    parsed = parse_response(Karma::Commands.call({v: 2, op: "snapshot.info"}.to_json, cluster))
    info = parsed["response"]

    parsed["protocol_version"].as_i.should eq(2)
    info["dump_count"].as_i.should eq(1)
    info["latest_by_tree"].as_a.first["tree"].as_s.should eq("articles")
    info["latest_by_tree"].as_a.first["last_lsn"].as_i.should be > 0
    info["last_snapshot_lsn"].as_i.should be > 0
    info["wal_enabled"].as_bool.should be_true
    info["wal_bytes"].as_i.should eq(0)
    info["wal_current_lsn"].as_i.should be > 0
  end

  it "fetches snapshot content for remote bootstrap" do
    dump_dir = File.expand_path(".spec_snapshot_fetch_#{Time.local.to_unix_ms}")
    Karma.configure { |c| c.dump_dir = dump_dir }
    cluster = Karma::Cluster.new

    Karma::Commands.call({v: 2, op: "counter.increment", tree: "articles", key: 42_u64}.to_json, cluster)
    cluster.dump_all
    file = File.basename(Karma::Backup.dumps(dump_dir).first)

    parsed = parse_response(Karma::Commands.call({v: 2, op: "snapshot.fetch", file: file}.to_json, cluster))
    response = parsed["response"]

    parsed["protocol_version"].as_i.should eq(2)
    parsed["success"].as_bool.should be_true
    response["metadata"]["file"].as_s.should eq(file)
    Base64.decode_string(response["data_base64"].as_s).bytesize.should eq(File.size(File.join(dump_dir, file)))

    io = IO::Memory.new
    offset = 0_u64
    loop do
      chunk = parse_response(Karma::Commands.call({
        v:      2,
        op:     "snapshot.fetch_chunk",
        file:   file,
        offset: offset,
        limit:  16,
      }.to_json, cluster))["response"]
      io.write Base64.decode(chunk["data_base64"].as_s)
      offset = chunk["next_offset"].as_i64.to_u64
      break if chunk["done"].as_bool
    end
    io.to_slice.should eq(File.read(File.join(dump_dir, file)).to_slice)

    bad_limit = parse_response(Karma::Commands.call({
      v:      2,
      op:     "snapshot.fetch_chunk",
      file:   file,
      offset: 0_u64,
      limit:  Karma::Backup::SNAPSHOT_CHUNK_MAX_BYTES + 1,
    }.to_json, cluster))
    bad_limit["success"].as_bool.should be_false
    bad_limit["error_code"].as_s.should eq("validation_error")

    bad = parse_response(Karma::Commands.call({v: 2, op: "snapshot.fetch", file: "../#{file}"}.to_json, cluster))
    bad["success"].as_bool.should be_false
    bad["error_code"].as_s.should eq("validation_error")
  end

  it "verifies restorable WAL while command lock is held" do
    dump_dir = File.expand_path(".spec_verify_wal_#{Time.local.to_unix_ms}")
    Karma.configure { |c| c.dump_dir = dump_dir }
    cluster = Karma::Cluster.new

    Karma::Commands.call({v: 2, op: "counter.increment", series: "articles", key: 42_u64}.to_json, cluster)

    parsed = expect_success(Karma::Commands.call({v: 2, op: "snapshot.verify"}.to_json, cluster))

    parsed["response"]["status"].as_s.should eq("ok")
    parsed["response"]["trees"].as_i.should eq(1)
    parsed["response"]["keys"].as_i.should eq(1)
  end
end

describe Karma::Backup do
  it "validates restored counter invariants" do
    cluster = Karma::Cluster.new
    tree = CounterTree::Tree.new
    counter = tree.get_or_create(42_u64)
    counter.insert(20230201_u64, 5_u64)
    counter.table[20230201_u64] = 7_u64
    cluster.trees["articles"] = tree

    expect_raises(Karma::Error, /failed validation/) do
      cluster.validate!
    end
  end

  it "keeps only configured number of dumps per tree" do
    dump_dir = File.expand_path(".spec_retention_#{Time.local.to_unix_ms}")
    Dir.mkdir_p(dump_dir)

    3.times do |index|
      dump_path = File.join(dump_dir, "#{index + 1}_articles.tree")
      File.write(dump_path, "dump")
      File.write(Karma::Backup.metadata_path(dump_path), "metadata")
    end

    Karma::Backup.prune(dump_dir, 2).should eq(1)
    Karma::Backup.dumps(dump_dir).map { |path| File.basename(path) }.should eq([
      "3_articles.tree",
      "2_articles.tree",
    ])
    File.exists?(Karma::Backup.metadata_path(File.join(dump_dir, "1_articles.tree"))).should be_false
  end
end
