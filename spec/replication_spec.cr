require "./spec_helper"

private def replication_entry(lsn : UInt64, key : UInt64, value : UInt64 = 1_u64) : Karma::Wal::Entry
  Karma::Wal::Entry.new(
    lsn,
    JSON.parse({
      v:     2,
      op:    "counter.increment",
      tree:  "links",
      key:   key,
      value: value,
    }.to_json)
  )
end

describe Karma::Replication do
  it "applies WAL entries on a slave without appending local WAL" do
    master_dir = File.expand_path(".spec_replication_master_#{Time.local.to_unix_ms}")
    slave_dir = File.expand_path(".spec_replication_slave_#{Time.local.to_unix_ms}")
    Karma.configure { |c| c.dump_dir = master_dir }
    master = Karma::Cluster.new

    Karma::Commands.call({v: 2, op: "counter.increment", tree: "links", key: 42_u64, value: 2_u64}.to_json, master)
    Karma::Commands.call({v: 2, op: "counter.increment", tree: "links", key: 42_u64, value: 3_u64}.to_json, master)
    entries = Karma::Wal.entries_after(0_u64, 100, master_dir)

    Karma.configure do |c|
      c.dump_dir = slave_dir
      c.role = "slave"
    end
    slave = Karma::Cluster.new

    Karma::Replication.apply(entries, slave, slave_dir).should eq(2_u64)

    slave.get("links").sum(42_u64).should eq(5_u64)
    Karma::Replication.replayed_lsn(slave_dir).should eq(2_u64)
    File.read(Karma::Replication.lsn_path(slave_dir)).strip.should eq("2")
    File.exists?(Karma::Wal.path(slave_dir)).should be_false
  ensure
    Karma.configure { |c| c.role = "master" }
  end

  it "loads replayed LSN from disk" do
    dump_dir = File.expand_path(".spec_replication_lsn_#{Time.local.to_unix_ms}")

    Karma::Replication.checkpoint(7_u64, dump_dir)
    Karma::Replication.reset!

    Karma::Replication.replayed_lsn(dump_dir).should eq(7_u64)
  end

  it "skips already replayed entries and applies the next LSN" do
    dump_dir = File.expand_path(".spec_replication_skip_#{Time.local.to_unix_ms}")
    cluster = Karma::Cluster.new

    Karma::Replication.checkpoint(1_u64, dump_dir)
    Karma::Replication.apply([
      replication_entry(1_u64, 41_u64),
      replication_entry(2_u64, 42_u64),
    ], cluster, dump_dir).should eq(2_u64)

    cluster.get("links").sum(41_u64).should eq(0_u64)
    cluster.get("links").sum(42_u64).should eq(1_u64)
  end

  it "rejects WAL gaps" do
    dump_dir = File.expand_path(".spec_replication_gap_#{Time.local.to_unix_ms}")
    cluster = Karma::Cluster.new

    Karma::Replication.checkpoint(1_u64, dump_dir)

    expect_raises(Karma::Error, /expected LSN 2, got 3/) do
      Karma::Replication.apply([replication_entry(3_u64, 42_u64)], cluster, dump_dir)
    end
    Karma::Replication.replayed_lsn(dump_dir).should eq(1_u64)
  end

  it "reports replication lag metrics for slave role" do
    dump_dir = File.expand_path(".spec_replication_status_#{Time.local.to_unix_ms}")
    Karma.configure { |c| c.role = "slave" }

    Karma::Replication.checkpoint(2_u64, dump_dir)
    status = Karma::Replication.status(5_u64, dump_dir)

    status[:replayed_lsn].should eq(2_u64)
    status[:source_lsn].should eq(5_u64)
    status[:lag_entries].should eq(3_u64)
  ensure
    Karma.configure { |c| c.role = "master" }
  end
end
