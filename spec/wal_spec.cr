require "./spec_helper"

describe Karma::Wal do
  it "writes mutating commands to WAL" do
    dump_dir = File.expand_path(".spec_wal_append_#{Time.local.to_unix_ms}")
    Karma.configure { |c| c.dump_dir = dump_dir }
    cluster = Karma::Cluster.new

    Karma::Commands.call({
      command:   "increment",
      tree_name: "articles",
      key:       42_u64,
    }.to_json, cluster)

    lines = File.read_lines(Karma::Wal.path(dump_dir))
    lines.size.should eq(1)
    lines.first.should contain("\"v\":2")
    lines.first.should contain("\"op\":\"counter.increment\"")
    lines.first.should contain("\"date\"")
    lines.first.should contain("\"value\":1")
  end

  it "replays WAL after snapshot restore" do
    dump_dir = File.expand_path(".spec_wal_replay_#{Time.local.to_unix_ms}")
    Karma.configure { |c| c.dump_dir = dump_dir }
    cluster = Karma::Cluster.new

    Karma::Commands.call({
      command:   "increment",
      tree_name: "articles",
      key:       42_u64,
    }.to_json, cluster)

    restored = Karma::Cluster.restore_with_wal(dump_dir)

    restored.trees.keys.should contain("articles")
    restored.get("articles").sum(42_u64).should eq(1_u64)
  end

  it "truncates WAL after dumping all trees" do
    dump_dir = File.expand_path(".spec_wal_compact_#{Time.local.to_unix_ms}")
    Karma.configure { |c| c.dump_dir = dump_dir }
    cluster = Karma::Cluster.new

    Karma::Commands.call({
      command:   "increment",
      tree_name: "articles",
      key:       42_u64,
    }.to_json, cluster)
    File.read(Karma::Wal.path(dump_dir)).should_not be_empty

    cluster.dump_all

    File.read(Karma::Wal.path(dump_dir)).should be_empty
    restored = Karma::Cluster.restore_with_wal(dump_dir)
    restored.get("articles").sum(42_u64).should eq(1_u64)
  end

  it "can disable WAL persistence" do
    dump_dir = File.expand_path(".spec_wal_disabled_#{Time.local.to_unix_ms}")
    Karma.configure do |c|
      c.dump_dir = dump_dir
      c.wal = false
    end
    cluster = Karma::Cluster.new

    Karma::Commands.call({
      command:   "increment",
      tree_name: "articles",
      key:       42_u64,
    }.to_json, cluster)

    File.exists?(Karma::Wal.path(dump_dir)).should be_false
  ensure
    Karma.configure { |c| c.wal = true }
  end

  it "can write WAL without fsync" do
    dump_dir = File.expand_path(".spec_wal_no_fsync_#{Time.local.to_unix_ms}")
    Karma.configure do |c|
      c.dump_dir = dump_dir
      c.wal_fsync = false
    end
    cluster = Karma::Cluster.new

    Karma::Commands.call({
      command:   "increment",
      tree_name: "articles",
      key:       42_u64,
    }.to_json, cluster)

    File.read(Karma::Wal.path(dump_dir)).should contain("\"op\":\"counter.increment\"")
  ensure
    Karma.configure { |c| c.wal_fsync = true }
  end

  it "does not persist auth token in WAL" do
    dump_dir = File.expand_path(".spec_wal_auth_#{Time.local.to_unix_ms}")
    Karma.configure do |c|
      c.dump_dir = dump_dir
      c.auth_token = "secret"
    end
    cluster = Karma::Cluster.new

    Karma::Commands.call({
      command:   "increment",
      tree_name: "articles",
      key:       42_u64,
      token:     "secret",
    }.to_json, cluster)

    wal = File.read(Karma::Wal.path(dump_dir))
    wal.should contain("\"op\":\"counter.increment\"")
    wal.should_not contain("secret")
    Karma::Cluster.restore_with_wal(dump_dir).get("articles").sum(42_u64).should eq(1_u64)
  ensure
    Karma.configure { |c| c.auth_token = nil }
  end

  it "replays legacy v1 WAL entries" do
    dump_dir = File.expand_path(".spec_wal_legacy_#{Time.local.to_unix_ms}")
    Karma.configure { |c| c.dump_dir = dump_dir }
    Dir.mkdir_p(dump_dir)
    File.write(Karma::Wal.path(dump_dir), {
      command:   "increment",
      tree_name: "articles",
      key:       42_u64,
    }.to_json + "\n")

    restored = Karma::Cluster.restore_with_wal(dump_dir)

    restored.get("articles").sum(42_u64).should eq(1_u64)
  end

  it "writes batch increments to one WAL entry and replays them" do
    dump_dir = File.expand_path(".spec_wal_batch_add_#{Time.local.to_unix_ms}")
    Karma.configure { |c| c.dump_dir = dump_dir }
    cluster = Karma::Cluster.new

    Karma::Commands.call({
      v:      2,
      op:     "series.batch_add",
      series: "articles",
      items:  [
        [42_u64, 20260505_u64, 10_u64],
        [43_u64, 20260505_u64, 7_u64],
      ],
    }.to_json, cluster)

    lines = File.read_lines(Karma::Wal.path(dump_dir))
    lines.size.should eq(1)
    lines.first.should contain("\"op\":\"series.batch_add\"")
    lines.first.should contain("\"items\"")

    restored = Karma::Cluster.restore_with_wal(dump_dir)
    restored.get("articles").sum(42_u64).should eq(10_u64)
    restored.get("articles").sum(43_u64).should eq(7_u64)
  end

  it "replays streaming ingest chunks idempotently" do
    dump_dir = File.expand_path(".spec_wal_ingest_#{Time.local.to_unix_ms}")
    Karma.configure { |c| c.dump_dir = dump_dir }
    cluster = Karma::Cluster.new

    Karma::Commands.call({v: 2, op: "ingest.begin", mode: "add", stream_id: "wal-stream"}.to_json, cluster)
    chunk = {
      v:         2,
      op:        "ingest.chunk",
      stream_id: "wal-stream",
      series:    "articles",
      chunk_seq: 1_u64,
      items:     [[42_u64, 20260505_u64, 10_u64]],
    }.to_json
    Karma::Commands.call(chunk, cluster)
    Karma::Commands.call(chunk, cluster)
    Karma::Commands.call({v: 2, op: "ingest.commit", stream_id: "wal-stream"}.to_json, cluster)

    lines = File.read_lines(Karma::Wal.path(dump_dir))
    lines.size.should eq(4)
    lines[0].should contain("\"op\":\"ingest.begin\"")
    lines[1].should contain("\"op\":\"ingest.chunk\"")
    lines[2].should contain("\"op\":\"ingest.chunk\"")
    lines[3].should contain("\"op\":\"ingest.commit\"")

    Karma::Ingest.reset!
    restored = Karma::Cluster.restore_with_wal(dump_dir)
    restored.get("articles").sum(42_u64).should eq(10_u64)
  end

  it "replays replace_series ingest with atomic commit" do
    dump_dir = File.expand_path(".spec_wal_ingest_replace_#{Time.local.to_unix_ms}")
    Karma.configure { |c| c.dump_dir = dump_dir }
    cluster = Karma::Cluster.new

    Karma::Commands.call({v: 2, op: "counter.increment", series: "articles", key: 1_u64, bucket: 20260505_u64, value: 99_u64}.to_json, cluster)
    Karma::Commands.call({v: 2, op: "ingest.begin", mode: "replace_series", stream_id: "replace-stream"}.to_json, cluster)
    Karma::Commands.call({
      v:         2,
      op:        "ingest.chunk",
      stream_id: "replace-stream",
      series:    "articles",
      chunk_seq: 1_u64,
      items:     [[2_u64, 20260505_u64, 5_u64]],
    }.to_json, cluster)
    Karma::Commands.call({v: 2, op: "ingest.commit", stream_id: "replace-stream"}.to_json, cluster)

    Karma::Ingest.reset!
    restored = Karma::Cluster.restore_with_wal(dump_dir)
    restored.get("articles").sum(1_u64).should eq(0_u64)
    restored.get("articles").sum(2_u64).should eq(5_u64)
  end

  it "replays retention and compact commands" do
    dump_dir = File.expand_path(".spec_wal_retention_#{Time.local.to_unix_ms}")
    Karma.configure { |c| c.dump_dir = dump_dir }
    cluster = Karma::Cluster.new

    Karma::Commands.call({v: 2, op: "counter.increment", tree: "articles", key: 42_u64, date: 20260501_u64, value: 2_u64}.to_json, cluster)
    Karma::Commands.call({v: 2, op: "counter.increment", tree: "articles", key: 42_u64, date: 20260503_u64, value: 3_u64}.to_json, cluster)
    Karma::Commands.call({v: 2, op: "series.delete_before", series: "articles", before: 20260503_u64}.to_json, cluster)
    Karma::Commands.call({v: 2, op: "counter.decrement", tree: "articles", key: 42_u64, date: 20260503_u64, value: 3_u64}.to_json, cluster)
    Karma::Commands.call({v: 2, op: "system.compact"}.to_json, cluster)

    wal = File.read(Karma::Wal.path(dump_dir))
    wal.should contain("\"op\":\"series.delete_before\"")
    wal.should contain("\"op\":\"system.compact\"")

    restored = Karma::Cluster.restore_with_wal(dump_dir)
    restored.get("articles").sum(42_u64).should eq(0_u64)
    restored.key_count.should eq(0)
  end
end
