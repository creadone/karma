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

private class FakeReplicationPoller < Karma::Replication::Poller
  def initialize(cluster : Karma::Cluster, @source_lsn : UInt64, @entries : Array(Karma::Wal::Entry))
    super(cluster, "fake-master", 0, 100, 10.milliseconds)
  end

  protected def request_entries(after_lsn : UInt64) : Karma::Replication::Poller::Response
    entries = @entries.select { |entry| entry.lsn > after_lsn }
    Karma::Replication::Poller::Response.new(@source_lsn, entries)
  end
end

private class FailingReplicationPoller < Karma::Replication::Poller
  def initialize(cluster : Karma::Cluster)
    super(cluster, "fake-master", 0, 100, 10.milliseconds)
  end

  protected def request_entries(after_lsn : UInt64) : Karma::Replication::Poller::Response
    raise Karma::Error.new("replication_error", "boom")
  end
end

private class FakeSnapshotClient < Karma::Replication::SnapshotClient
  def initialize(@info_response : JSON::Any, @master_dir : String)
    super("fake-master", 0)
  end

  protected def request(payload : String) : JSON::Any
    parsed = JSON.parse(payload)
    case parsed["op"].as_s
    when "snapshot.info"
      @info_response
    when "snapshot.fetch_chunk"
      file = parsed["file"].as_s
      offset = parsed["offset"].as_i64.to_u64
      limit = parsed["limit"].as_i.to_i32
      JSON.parse(Karma::Backup.fetch_chunk(File.join(@master_dir, file), offset, limit).to_json)
    when "idempotency.snapshot_fetch_chunk"
      offset = parsed["offset"].as_i64.to_u64
      limit = parsed["limit"].as_i.to_i32
      JSON.parse(Karma::Idempotency.fetch_chunk(offset, limit, @master_dir).to_json)
    else
      raise "Unexpected op #{parsed["op"].as_s}"
    end
  end
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

  it "stores replayed LSN in slave snapshots" do
    dump_dir = File.expand_path(".spec_replication_snapshot_lsn_#{Time.local.to_unix_ms}")
    Karma.configure do |c|
      c.dump_dir = dump_dir
      c.role = "slave"
    end
    cluster = Karma::Cluster.new

    Karma::Replication.apply([
      replication_entry(1_u64, 42_u64, 2_u64),
      replication_entry(2_u64, 43_u64, 3_u64),
    ], cluster, dump_dir)
    cluster.dump_all

    snapshot = Karma::Backup.latest_snapshot_metadata_by_tree(dump_dir).first
    snapshot.last_lsn.should eq(2_u64)
    Karma::Backup.restore_lsn(dump_dir).should eq(2_u64)
  ensure
    Karma.configure { |c| c.role = "master" }
  end

  it "bootstraps replayed LSN from restored slave snapshots" do
    dump_dir = File.expand_path(".spec_replication_bootstrap_snapshot_#{Time.local.to_unix_ms}")
    Karma.configure do |c|
      c.dump_dir = dump_dir
      c.role = "slave"
    end
    cluster = Karma::Cluster.new

    Karma::Replication.apply([
      replication_entry(1_u64, 42_u64, 2_u64),
      replication_entry(2_u64, 43_u64, 3_u64),
    ], cluster, dump_dir)
    cluster.dump_all
    File.delete(Karma::Replication.lsn_path(dump_dir))
    Karma::Replication.reset!

    Karma::Replication.bootstrap_from_snapshots(dump_dir).should eq(2_u64)
    Karma::Replication.replayed_lsn(dump_dir).should eq(2_u64)
  ensure
    Karma.configure { |c| c.role = "master" }
  end

  it "installs remote snapshots for empty slave bootstrap" do
    master_dir = File.expand_path(".spec_replication_remote_master_#{Time.local.to_unix_ms}")
    slave_dir = File.expand_path(".spec_replication_remote_slave_#{Time.local.to_unix_ms}")
    Karma.configure { |c| c.dump_dir = master_dir }
    master = Karma::Cluster.new
    idempotent_request = {
      v:               2,
      op:              "series.batch_add",
      series:          "links",
      items:           [[42_u64, 20260529_u64, 5_u64]],
      idempotency_key: "replication-bootstrap-event",
    }.to_json

    Karma::Commands.call({v: 2, op: "counter.increment", tree: "links", key: 42_u64, value: 7_u64}.to_json, master)
    Karma::Commands.call(idempotent_request, master)
    master.dump_all
    info = JSON.parse(Karma::Backup.info(master_dir).to_json)
    client = FakeSnapshotClient.new(info, master_dir)

    client.bootstrap_files(slave_dir).should eq(2_u64)
    Karma::Backup.restore_lsn(slave_dir).should eq(2_u64)
    restored = Karma::Cluster.restore_with_wal(slave_dir)
    repeat = parse_response(Karma::Commands.call(idempotent_request, restored))

    repeat["success"].as_bool.should be_true
    repeat["idempotent"].as_bool.should be_true
    restored.get("links").sum(42_u64).should eq(12_u64)
  end

  it "installs idempotency-only snapshots for empty slave bootstrap" do
    master_dir = File.expand_path(".spec_replication_idempotency_master_#{Time.local.to_unix_ms}")
    slave_dir = File.expand_path(".spec_replication_idempotency_slave_#{Time.local.to_unix_ms}")
    Karma.configure { |c| c.dump_dir = master_dir }
    master = Karma::Cluster.new

    Karma::Commands.call({v: 2, op: "ingest.begin", stream_id: "empty-import", mode: "add"}.to_json, master)
    Karma::Commands.call({v: 2, op: "ingest.commit", stream_id: "empty-import"}.to_json, master)
    master.dump_all
    info = JSON.parse(Karma::Backup.info(master_dir).to_json)
    client = FakeSnapshotClient.new(info, master_dir)

    client.bootstrap_files(slave_dir).should eq(2_u64)
    Karma::Backup.restore_lsn(slave_dir).should eq(2_u64)
    restored = Karma::Cluster.restore_with_wal(slave_dir)
    repeat = parse_response(Karma::Commands.call({v: 2, op: "ingest.commit", stream_id: "empty-import"}.to_json, restored))

    repeat["success"].as_bool.should be_true
    repeat["response"]["status"].as_s.should eq("already_committed")
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

  it "records poll success and error metrics" do
    master_dir = File.expand_path(".spec_replication_poll_metrics_master_#{Time.local.to_unix_ms}")
    slave_dir = File.expand_path(".spec_replication_poll_metrics_slave_#{Time.local.to_unix_ms}")
    Karma.configure { |c| c.dump_dir = master_dir }
    master = Karma::Cluster.new

    Karma::Commands.call({v: 2, op: "counter.increment", tree: "links", key: 42_u64}.to_json, master)
    entries = Karma::Wal.entries_after(0_u64, 100, master_dir)

    Karma.configure do |c|
      c.dump_dir = slave_dir
      c.role = "slave"
    end
    slave = Karma::Cluster.new

    FakeReplicationPoller.new(slave, Karma::Wal.current_lsn(master_dir), entries).poll_once.should eq(1_u64)
    status = Karma::Replication.status
    status[:poll_attempt_count].should eq(1)
    status[:poll_success_count].should eq(1)
    status[:poll_error_count].should eq(0)
    status[:last_poll_success_unix].should be > 0
    status[:last_poll_error].should be_nil

    expect_raises(Karma::Error, "boom") do
      FailingReplicationPoller.new(slave).poll_once
    end
    failed = Karma::Replication.status
    failed[:poll_attempt_count].should eq(2)
    failed[:poll_error_count].should eq(1)
    failed[:last_poll_error].should eq("boom")
    failed[:last_poll_error_unix].should be > 0
  ensure
    Karma.configure { |c| c.role = "master" }
  end

  it "polls replication entries from master transport" do
    master_dir = File.expand_path(".spec_replication_poll_master_#{Time.local.to_unix_ms}")
    slave_dir = File.expand_path(".spec_replication_poll_slave_#{Time.local.to_unix_ms}")
    Karma.configure { |c| c.dump_dir = master_dir }
    master = Karma::Cluster.new

    Karma::Commands.call({v: 2, op: "counter.increment", tree: "links", key: 42_u64, value: 4_u64}.to_json, master)
    Karma::Commands.call({v: 2, op: "counter.increment", tree: "links", key: 43_u64, value: 5_u64}.to_json, master)
    entries = Karma::Wal.entries_after(0_u64, 100, master_dir)

    Karma.configure do |c|
      c.dump_dir = slave_dir
      c.role = "slave"
    end
    slave = Karma::Cluster.new
    poller = FakeReplicationPoller.new(slave, Karma::Wal.current_lsn(master_dir), entries)

    poller.poll_once.should eq(2_u64)

    slave.get("links").sum(42_u64).should eq(4_u64)
    slave.get("links").sum(43_u64).should eq(5_u64)
    Karma::Replication.status["source_lsn"].should eq(2_u64)
    Karma::Replication.status["lag_entries"].should eq(0_u64)
  ensure
    Karma.configure { |c| c.role = "master" }
  end
end
