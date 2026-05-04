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
    lines.first.should contain("\"command\":\"increment\"")
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

    File.read(Karma::Wal.path(dump_dir)).should contain("\"command\":\"increment\"")
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
    wal.should contain("\"command\":\"increment\"")
    wal.should_not contain("secret")
    Karma::Cluster.restore_with_wal(dump_dir).get("articles").sum(42_u64).should eq(1_u64)
  ensure
    Karma.configure { |c| c.auth_token = nil }
  end
end
