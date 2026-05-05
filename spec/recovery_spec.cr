require "./spec_helper"

describe Karma::Recovery do
  it "records and returns recovery checkpoints" do
    dump_dir = File.expand_path(".spec_recovery_checkpoint_#{Time.local.to_unix_ms}")
    Karma.configure { |c| c.dump_dir = dump_dir }
    cluster = Karma::Cluster.new

    response = parse_response(Karma::Commands.call({
      v:        2,
      op:       "recovery.checkpoint",
      source:   "clickhouse-links",
      offset:   12345_i64,
      event_id: "export-2026-05-05",
    }.to_json, cluster))

    response["protocol_version"].as_i.should eq(2)
    response["success"].as_bool.should be_true
    response["response"]["source"].as_s.should eq("clickhouse-links")
    response["response"]["offset"].as_s.should eq("12345")
    response["response"]["event_id"].as_s.should eq("export-2026-05-05")
    response["response"]["updated_at_unix"].as_i.should be > 0

    status = parse_response(Karma::Commands.call({v: 2, op: "recovery.status"}.to_json, cluster))["response"]
    status["checkpoint_count"].as_i.should eq(1)
    status["checkpoints"].as_a.first["source"].as_s.should eq("clickhouse-links")
  ensure
    Karma.configure { |c| c.dump_dir = "." }
  end

  it "persists checkpoints outside WAL and reloads them" do
    dump_dir = File.expand_path(".spec_recovery_reload_#{Time.local.to_unix_ms}")
    Karma.configure do |c|
      c.dump_dir = dump_dir
      c.wal = true
    end
    cluster = Karma::Cluster.new

    Karma::Commands.call({
      v:      2,
      op:     "recovery.checkpoint",
      source: "kafka-clicks",
      offset: "topic=clicks partition=0 offset=9001",
    }.to_json, cluster)

    File.exists?(Karma::Recovery.path(dump_dir)).should be_true
    File.exists?(Karma::Wal.path(dump_dir)).should be_false

    Karma::Recovery.reset!
    Karma::Recovery.load!(dump_dir)
    status = Karma::Recovery.status("kafka-clicks")

    status[:checkpoint_count].should eq(1)
    status[:checkpoints].first[:offset].should eq("topic=clicks partition=0 offset=9001")
  ensure
    Karma.configure do |c|
      c.dump_dir = "."
      c.wal = true
    end
  end

  it "clears in-memory checkpoints when loading an empty directory" do
    existing_dir = File.expand_path(".spec_recovery_existing_#{Time.local.to_unix_ms}")
    empty_dir = File.expand_path(".spec_recovery_empty_#{Time.local.to_unix_ms}")
    Dir.mkdir_p(empty_dir)

    Karma::Recovery.checkpoint("clickhouse-links", "1", nil, existing_dir)

    Karma::Recovery.load!(empty_dir)

    Karma::Recovery.status[:checkpoint_count].should eq(0)
  end

  it "rejects incomplete checkpoints" do
    cluster = Karma::Cluster.new

    response = parse_response(Karma::Commands.call({
      v:      2,
      op:     "recovery.checkpoint",
      source: "clickhouse-links",
    }.to_json, cluster))

    response["protocol_version"].as_i.should eq(2)
    response["success"].as_bool.should be_false
    response["error_code"].as_s.should eq("validation_error")
  end

  it "allows read-only tokens to read status but not write checkpoints" do
    Karma.configure do |c|
      c.auth_token = "write-secret"
      c.read_auth_token = "read-secret"
    end
    cluster = Karma::Cluster.new

    status = parse_response(Karma::Commands.call({
      v:     2,
      op:    "recovery.status",
      token: "read-secret",
    }.to_json, cluster))
    status["success"].as_bool.should be_true

    checkpoint = parse_response(Karma::Commands.call({
      v:      2,
      op:     "recovery.checkpoint",
      source: "clickhouse-links",
      offset: "1",
      token:  "read-secret",
    }.to_json, cluster))
    checkpoint["success"].as_bool.should be_false
    checkpoint["error_code"].as_s.should eq("forbidden")
  ensure
    Karma.configure do |c|
      c.auth_token = nil
      c.read_auth_token = nil
    end
  end
end
