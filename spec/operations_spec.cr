require "./spec_helper"

describe "operations commands" do
  it "returns health response" do
    cluster = Karma::Cluster.new

    parsed = expect_success(Karma::Commands.call({command: "health"}.to_json, cluster))

    parsed["response"]["status"].as_s.should eq("ok")
    parsed["response"]["wal_enabled"].as_bool.should be_true
  end

  it "returns stats response" do
    dump_dir = File.expand_path(".spec_stats_#{Time.local.to_unix_ms}")
    Karma.configure { |c| c.dump_dir = dump_dir }
    cluster = Karma::Cluster.new

    Karma::Commands.call({command: "increment", tree_name: "articles", key: 42_u64}.to_json, cluster)

    parsed = expect_success(Karma::Commands.call({command: "stats"}.to_json, cluster))

    parsed["response"]["trees"].as_i.should eq(1)
    parsed["response"]["keys"].as_i.should eq(1)
    parsed["response"]["wal_bytes"].as_i.should be > 0
    parsed["response"]["memory_bytes"].as_i.should be > 0
    parsed["response"]["command_count"].as_i.should be > 0
    parsed["response"]["latency_ms_last"].as_f.should be >= 0.0
    parsed["response"]["ingest_active_streams"].as_i.should eq(0)
  end

  it "returns metrics response" do
    cluster = Karma::Cluster.new

    parsed = expect_success(Karma::Commands.call({command: "metrics"}.to_json, cluster))

    metrics = parsed["response"].as_s
    metrics.should contain("karma_uptime_seconds")
    metrics.should contain("karma_trees")
    metrics.should contain("karma_memory_bytes")
    metrics.should contain("karma_commands_total")
    metrics.should contain("karma_errors_total")
    metrics.should contain("karma_command_latency_ms")
    metrics.should contain("karma_ingest_active_streams")
    metrics.should contain("karma_ingest_chunks_applied_total")
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

    stats = expect_success(Karma::Commands.call({command: "stats"}.to_json, cluster))["response"]
    stats["ingest_active_streams"].as_i.should eq(1)
    stats["ingest_chunks_applied"].as_i.should eq(1)
    stats["ingest_chunks_skipped"].as_i.should eq(1)
    stats["ingest_chunks_rejected"].as_i.should eq(1)
    stats["ingest_items_applied"].as_i.should eq(1)
    stats["ingest_latency_ms_last"].as_f.should be >= 0.0

    metrics = expect_success(Karma::Commands.call({command: "metrics"}.to_json, cluster))["response"].as_s
    metrics.should contain("karma_ingest_active_streams 1")
    metrics.should contain("karma_ingest_chunks_applied_total 1")
    metrics.should contain("karma_ingest_chunks_skipped_total 1")
    metrics.should contain("karma_ingest_chunks_rejected_total 1")
    metrics.should contain("karma_ingest_items_applied_total 1")
  end

  it "verifies restorable dumps" do
    dump_dir = File.expand_path(".spec_verify_#{Time.local.to_unix_ms}")
    Karma.configure { |c| c.dump_dir = dump_dir }
    cluster = Karma::Cluster.new

    Karma::Commands.call({command: "increment", tree_name: "articles", key: 42_u64}.to_json, cluster)
    cluster.dump_all

    parsed = expect_success(Karma::Commands.call({command: "verify"}.to_json, cluster))

    parsed["response"]["status"].as_s.should eq("ok")
    parsed["response"]["trees"].as_i.should eq(1)
    parsed["response"]["keys"].as_i.should eq(1)
  end

  it "returns snapshot info" do
    dump_dir = File.expand_path(".spec_snapshot_info_#{Time.local.to_unix_ms}")
    Karma.configure { |c| c.dump_dir = dump_dir }
    cluster = Karma::Cluster.new

    Karma::Commands.call({command: "increment", tree_name: "articles", key: 42_u64}.to_json, cluster)
    cluster.dump_all

    parsed = parse_response(Karma::Commands.call({v: 2, op: "snapshot.info"}.to_json, cluster))
    info = parsed["response"]

    parsed["protocol_version"].as_i.should eq(2)
    info["dump_count"].as_i.should eq(1)
    info["latest_by_tree"].as_a.first["tree"].as_s.should eq("articles")
    info["wal_enabled"].as_bool.should be_true
    info["wal_bytes"].as_i.should eq(0)
  end

  it "verifies restorable WAL while command lock is held" do
    dump_dir = File.expand_path(".spec_verify_wal_#{Time.local.to_unix_ms}")
    Karma.configure { |c| c.dump_dir = dump_dir }
    cluster = Karma::Cluster.new

    Karma::Commands.call({command: "increment", tree_name: "articles", key: 42_u64}.to_json, cluster)

    parsed = expect_success(Karma::Commands.call({command: "verify"}.to_json, cluster))

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
      File.write(File.join(dump_dir, "#{index + 1}_articles.tree"), "dump")
    end

    Karma::Backup.prune(dump_dir, 2).should eq(1)
    Karma::Backup.dumps(dump_dir).map { |path| File.basename(path) }.should eq([
      "3_articles.tree",
      "2_articles.tree",
    ])
  end
end
