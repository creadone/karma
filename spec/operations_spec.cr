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
