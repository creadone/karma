require "./spec_helper"

describe Karma::Commands do
  it "does not create tree when summing missing tree" do
    cluster = Karma::Cluster.new

    response = Karma::Commands.call({
      command:   "sum",
      tree_name: "missing",
      key:       42_u64,
    }.to_json, cluster)

    parsed = expect_error(response, "not_found")
    parsed["response"].as_s.should eq("Tree \"missing\" not found")
    cluster.trees.has_key?("missing").should be_false
  end

  it "does not create tree when finding missing tree" do
    cluster = Karma::Cluster.new

    response = Karma::Commands.call({
      command:   "find",
      tree_name: "missing",
      key:       42_u64,
      time_from: 20230201_u64,
      time_to:   20230202_u64,
    }.to_json, cluster)

    parsed = expect_error(response, "not_found")
    parsed["response"].as_s.should eq("Tree \"missing\" not found")
    cluster.trees.has_key?("missing").should be_false
  end

  it "returns stable validation errors" do
    cluster = Karma::Cluster.new

    response = Karma::Commands.call({
      command: "increment",
      key:     42_u64,
    }.to_json, cluster)

    parsed = expect_error(response, "validation_error")
    parsed["response"].as_s.should eq("Field tree_name is required")
  end

  it "returns stable unknown command errors" do
    cluster = Karma::Cluster.new

    response = Karma::Commands.call({command: "nope"}.to_json, cluster)

    parsed = expect_error(response, "unknown_command")
    parsed["response"].as_s.should eq("Unknown command nope")
  end

  it "returns stable invalid JSON errors" do
    cluster = Karma::Cluster.new

    response = Karma::Commands.call("{", cluster)

    expect_error(response, "invalid_json")
  end

  it "rejects direct commands that exceed max request bytes" do
    Karma.configure { |c| c.max_request_bytes = 40 }
    cluster = Karma::Cluster.new

    response = Karma::Commands.call({
      v:     2,
      op:    "system.ping",
      token: "large-token-value",
    }.to_json, cluster)
    parsed = parse_response(response)

    parsed["protocol_version"].as_i.should eq(2)
    parsed["success"].as_bool.should be_false
    parsed["error_code"].as_s.should eq("request_too_large")
  ensure
    Karma.configure { |c| c.max_request_bytes = 4096 }
  end

  it "requires token when auth is configured" do
    Karma.configure { |c| c.auth_token = "secret" }
    cluster = Karma::Cluster.new

    response = Karma::Commands.call({command: "ping"}.to_json, cluster)

    expect_error(response, "unauthorized")
  ensure
    Karma.configure { |c| c.auth_token = nil }
  end

  it "accepts matching auth token" do
    Karma.configure { |c| c.auth_token = "secret" }
    cluster = Karma::Cluster.new

    response = Karma::Commands.call({command: "ping", token: "secret"}.to_json, cluster)

    parsed = expect_success(response)
    parsed["response"].as_s.should eq("pong")
  ensure
    Karma.configure { |c| c.auth_token = nil }
  end

  it "accepts read-only token for read commands" do
    Karma.configure do |c|
      c.auth_token = "write-secret"
      c.read_auth_token = "read-secret"
    end
    cluster = Karma::Cluster.new

    Karma::Commands.call({v: 2, op: "tree.create", tree: "links", token: "write-secret"}.to_json, cluster)
    response = Karma::Commands.call({v: 2, op: "tree.info", tree: "links", token: "read-secret"}.to_json, cluster)
    parsed = parse_response(response)

    parsed["success"].as_bool.should be_true
    parsed["response"]["tree"].as_s.should eq("links")
  ensure
    Karma.configure do |c|
      c.auth_token = nil
      c.read_auth_token = nil
    end
  end

  it "rejects read-only token for write and admin commands" do
    Karma.configure do |c|
      c.auth_token = "write-secret"
      c.read_auth_token = "read-secret"
    end
    cluster = Karma::Cluster.new

    write_response = Karma::Commands.call({
      v:     2,
      op:    "counter.increment",
      tree:  "links",
      key:   42_u64,
      token: "read-secret",
    }.to_json, cluster)
    write_error = parse_response(write_response)

    write_error["success"].as_bool.should be_false
    write_error["error_code"].as_s.should eq("forbidden")

    admin_response = Karma::Commands.call({
      v:     2,
      op:    "system.compact",
      token: "read-secret",
    }.to_json, cluster)
    admin_error = parse_response(admin_response)

    admin_error["success"].as_bool.should be_false
    admin_error["error_code"].as_s.should eq("forbidden")
  ensure
    Karma.configure do |c|
      c.auth_token = nil
      c.read_auth_token = nil
    end
  end

  it "accepts write token for all commands when read token is configured" do
    Karma.configure do |c|
      c.auth_token = "write-secret"
      c.read_auth_token = "read-secret"
    end
    cluster = Karma::Cluster.new

    response = Karma::Commands.call({
      v:     2,
      op:    "counter.increment",
      tree:  "links",
      key:   42_u64,
      token: "write-secret",
    }.to_json, cluster)
    parsed = parse_response(response)

    parsed["success"].as_bool.should be_true
    cluster.get("links").sum(42_u64).should eq(1_u64)
  ensure
    Karma.configure do |c|
      c.auth_token = nil
      c.read_auth_token = nil
    end
  end

  it "requires some configured token when only read token is configured" do
    Karma.configure { |c| c.read_auth_token = "read-secret" }
    cluster = Karma::Cluster.new

    missing = parse_response(Karma::Commands.call({v: 2, op: "system.ping"}.to_json, cluster))
    missing["success"].as_bool.should be_false
    missing["error_code"].as_s.should eq("unauthorized")

    allowed = parse_response(Karma::Commands.call({v: 2, op: "system.ping", token: "read-secret"}.to_json, cluster))
    allowed["success"].as_bool.should be_true
  ensure
    Karma.configure { |c| c.read_auth_token = nil }
  end

  it "rejects mutating client commands on slave role" do
    Karma.configure { |c| c.role = "slave" }
    cluster = Karma::Cluster.new

    write_response = parse_response(Karma::Commands.call({
      v:      2,
      op:     "counter.increment",
      series: "links",
      key:    42_u64,
    }.to_json, cluster))

    write_response["protocol_version"].as_i.should eq(2)
    write_response["success"].as_bool.should be_false
    write_response["error_code"].as_s.should eq("forbidden")
    cluster.trees.has_key?("links").should be_false

    admin_response = parse_response(Karma::Commands.call({v: 2, op: "snapshot.create_all"}.to_json, cluster))
    admin_response["success"].as_bool.should be_false
    admin_response["error_code"].as_s.should eq("forbidden")

    read_response = parse_response(Karma::Commands.call({v: 2, op: "system.stats"}.to_json, cluster))
    read_response["success"].as_bool.should be_true
    read_response["response"]["role"].as_s.should eq("slave")
  ensure
    Karma.configure { |c| c.role = "master" }
  end

  it "supports v2 system operations" do
    cluster = Karma::Cluster.new

    response = Karma::Commands.call({v: 2, op: "system.ping"}.to_json, cluster)
    parsed = parse_response(response)

    parsed["protocol_version"].as_i.should eq(2)
    parsed["success"].as_bool.should be_true
    parsed["response"].as_s.should eq("pong")
  end

  it "supports v2 tree operations" do
    cluster = Karma::Cluster.new

    create_response = parse_response(Karma::Commands.call({v: 2, op: "tree.create", tree: "links"}.to_json, cluster))
    create_response["protocol_version"].as_i.should eq(2)
    create_response["success"].as_bool.should be_true
    response = Karma::Commands.call({v: 2, op: "tree.list"}.to_json, cluster)
    parsed = parse_response(response)

    parsed["protocol_version"].as_i.should eq(2)
    parsed["response"].as_a.map(&.as_s).should contain("links")
  end

  it "supports v2 counter increment with explicit date and value" do
    cluster = Karma::Cluster.new

    response = Karma::Commands.call({
      v:     2,
      op:    "counter.increment",
      tree:  "links",
      key:   42_u64,
      date:  20260505_u64,
      value: 7_u64,
    }.to_json, cluster)
    parsed = parse_response(response)

    parsed["protocol_version"].as_i.should eq(2)
    parsed["success"].as_bool.should be_true
    parsed["response"].as_i.should eq(7)
    cluster.get("links").sum(42_u64, 20260505_u64, 20260505_u64).should eq(7_u64)
  end

  it "supports v2 range reads" do
    cluster = Karma::Cluster.new

    Karma::Commands.call({v: 2, op: "counter.increment", tree: "links", key: 42_u64, date: 20260501_u64, value: 2_u64}.to_json, cluster)
    Karma::Commands.call({v: 2, op: "counter.increment", tree: "links", key: 42_u64, date: 20260502_u64, value: 3_u64}.to_json, cluster)

    response = Karma::Commands.call({
      v:     2,
      op:    "counter.sum",
      tree:  "links",
      key:   42_u64,
      range: {from: 20260501_u64, to: 20260502_u64},
    }.to_json, cluster)
    parsed = parse_response(response)

    parsed["protocol_version"].as_i.should eq(2)
    parsed["response"].as_i.should eq(5)
  end

  it "supports v2 batch sums in request order" do
    cluster = Karma::Cluster.new

    Karma::Commands.call({v: 2, op: "counter.increment", tree: "links", key: 42_u64, date: 20260501_u64, value: 2_u64}.to_json, cluster)
    Karma::Commands.call({v: 2, op: "counter.increment", tree: "links", key: 43_u64, date: 20260501_u64, value: 3_u64}.to_json, cluster)

    response = Karma::Commands.call({
      v:    2,
      op:   "counter.batch_sum",
      tree: "links",
      keys: [43_u64, 999_u64, 42_u64, 42_u64],
    }.to_json, cluster)
    parsed = parse_response(response)
    values = parsed["response"].as_a

    parsed["protocol_version"].as_i.should eq(2)
    values.map { |item| item["key"].as_i }.should eq([43, 999, 42, 42])
    values.map { |item| item["value"].as_i }.should eq([3, 0, 2, 2])
  end

  it "supports v2 batch sums over a range" do
    cluster = Karma::Cluster.new

    Karma::Commands.call({v: 2, op: "counter.increment", tree: "links", key: 42_u64, date: 20260501_u64, value: 2_u64}.to_json, cluster)
    Karma::Commands.call({v: 2, op: "counter.increment", tree: "links", key: 42_u64, date: 20260503_u64, value: 9_u64}.to_json, cluster)

    response = Karma::Commands.call({
      v:     2,
      op:    "counter.batch_sum",
      tree:  "links",
      keys:  [42_u64],
      range: {from: 20260501_u64, to: 20260502_u64},
    }.to_json, cluster)
    parsed = parse_response(response)

    parsed["response"].as_a.first["value"].as_i.should eq(2)
  end

  it "supports empty v2 batch sums" do
    cluster = Karma::Cluster.new
    Karma::Commands.call({v: 2, op: "tree.create", tree: "links"}.to_json, cluster)

    response = Karma::Commands.call({v: 2, op: "counter.batch_sum", tree: "links", keys: [] of UInt64}.to_json, cluster)
    parsed = parse_response(response)

    parsed["success"].as_bool.should be_true
    parsed["response"].as_a.should be_empty
  end

  it "supports max-size v2 batch add and batch sum when byte limits allow it" do
    Karma.configure do |c|
      c.max_request_bytes = 1_048_576
      c.max_response_bytes = 1_048_576
    end
    cluster = Karma::Cluster.new
    keys = (1_u64..10_000_u64).to_a
    items = keys.map { |key| [key, 20260505_u64, 1_u64] }

    add_response = Karma::Commands.call({
      v:      2,
      op:     "series.batch_add",
      series: "links",
      items:  items,
    }.to_json, cluster)
    add = parse_response(add_response)

    add["success"].as_bool.should be_true
    add["response"]["applied"].as_i.should eq(10_000)
    add["response"]["total"].as_i.should eq(10_000)

    sum_response = Karma::Commands.call({
      v:      2,
      op:     "counter.batch_sum",
      series: "links",
      keys:   keys,
    }.to_json, cluster)
    sums = parse_response(sum_response)
    values = sums["response"].as_a

    sums["success"].as_bool.should be_true
    values.size.should eq(10_000)
    values.first["key"].as_i.should eq(1)
    values.first["value"].as_i.should eq(1)
    values.last["key"].as_i.should eq(10_000)
    values.last["value"].as_i.should eq(1)
  ensure
    Karma.configure do |c|
      c.max_request_bytes = 4096
      c.max_response_bytes = 1_048_576
    end
  end

  it "rejects responses that exceed max response bytes" do
    cluster = Karma::Cluster.new
    Karma::Commands.call({v: 2, op: "tree.create", tree: "links"}.to_json, cluster)
    Karma.configure { |c| c.max_response_bytes = 120 }

    response = Karma::Commands.call({
      v:    2,
      op:   "counter.batch_sum",
      tree: "links",
      keys: [1_u64, 2_u64, 3_u64, 4_u64, 5_u64],
    }.to_json, cluster)
    parsed = parse_response(response)

    parsed["protocol_version"].as_i.should eq(2)
    parsed["success"].as_bool.should be_false
    parsed["error_code"].as_s.should eq("response_too_large")
  ensure
    Karma.configure { |c| c.max_response_bytes = 1_048_576 }
  end

  it "supports v2 batch increments" do
    cluster = Karma::Cluster.new

    response = Karma::Commands.call({
      v:           2,
      op:          "series.batch_add",
      series:      "links",
      granularity: "day",
      items:       [
        [42_u64, 20260505_u64, 10_u64],
        [43_u64, 20260505_u64, 7_u64],
        [42_u64, 20260506_u64, 2_u64],
      ],
    }.to_json, cluster)
    parsed = parse_response(response)

    parsed["protocol_version"].as_i.should eq(2)
    parsed["success"].as_bool.should be_true
    parsed["response"]["applied"].as_i.should eq(3)
    parsed["response"]["total"].as_i.should eq(19)
    cluster.get("links").sum(42_u64).should eq(12_u64)
    cluster.get("links").sum(43_u64).should eq(7_u64)
  end

  it "supports v2 counter batch increment alias" do
    cluster = Karma::Cluster.new

    response = Karma::Commands.call({
      v:     2,
      op:    "counter.batch_increment",
      tree:  "links",
      items: [[42_u64, 20260505_u64, 3_u64]],
    }.to_json, cluster)
    parsed = parse_response(response)

    parsed["success"].as_bool.should be_true
    cluster.get("links").sum(42_u64, 20260505_u64, 20260505_u64).should eq(3_u64)
  end

  it "rejects malformed v2 batch increment items before applying them" do
    cluster = Karma::Cluster.new

    response = Karma::Commands.call({
      v:      2,
      op:     "series.batch_add",
      series: "links",
      items:  [[42_u64, 20260505_u64, 3_u64], [43_u64, 20260505_u64]],
    }.to_json, cluster)
    parsed = parse_response(response)

    parsed["protocol_version"].as_i.should eq(2)
    parsed["success"].as_bool.should be_false
    parsed["error_code"].as_s.should eq("validation_error")
    cluster.trees.has_key?("links").should be_false
  end

  it "rejects zero-value v2 batch increment items before applying them" do
    cluster = Karma::Cluster.new

    response = Karma::Commands.call({
      v:      2,
      op:     "series.batch_add",
      series: "links",
      items:  [[42_u64, 20260505_u64, 0_u64]],
    }.to_json, cluster)
    parsed = parse_response(response)

    parsed["success"].as_bool.should be_false
    parsed["error_code"].as_s.should eq("validation_error")
    cluster.trees.has_key?("links").should be_false
  end

  it "supports v2 streaming ingest add chunks" do
    cluster = Karma::Cluster.new

    begin_response = parse_response(Karma::Commands.call({
      v:           2,
      op:          "ingest.begin",
      mode:        "add",
      stream_id:   "stream-1",
      granularity: "day",
    }.to_json, cluster))
    begin_response["success"].as_bool.should be_true
    begin_response["response"]["last_chunk_seq"].as_i.should eq(0)

    chunk_response = parse_response(Karma::Commands.call({
      v:         2,
      op:        "ingest.chunk",
      stream_id: "stream-1",
      series:    "links",
      chunk_seq: 1_u64,
      items:     [[42_u64, 20260505_u64, 10_u64], [43_u64, 20260505_u64, 7_u64]],
    }.to_json, cluster))
    chunk_response["success"].as_bool.should be_true
    chunk_response["response"]["skipped"].as_bool.should be_false
    chunk_response["response"]["applied"].as_i.should eq(2)
    cluster.get("links").sum(42_u64).should eq(10_u64)
    cluster.get("links").sum(43_u64).should eq(7_u64)

    commit_response = parse_response(Karma::Commands.call({
      v:         2,
      op:        "ingest.commit",
      stream_id: "stream-1",
    }.to_json, cluster))
    commit_response["success"].as_bool.should be_true
    commit_response["response"]["status"].as_s.should eq("committed")
  end

  it "skips duplicate v2 streaming ingest chunks" do
    cluster = Karma::Cluster.new

    Karma::Commands.call({v: 2, op: "ingest.begin", mode: "add", stream_id: "stream-dup"}.to_json, cluster)
    chunk = {
      v:         2,
      op:        "ingest.chunk",
      stream_id: "stream-dup",
      series:    "links",
      chunk_seq: 1_u64,
      items:     [[42_u64, 20260505_u64, 10_u64]],
    }.to_json

    Karma::Commands.call(chunk, cluster)
    duplicate = parse_response(Karma::Commands.call(chunk, cluster))

    duplicate["success"].as_bool.should be_true
    duplicate["response"]["skipped"].as_bool.should be_true
    cluster.get("links").sum(42_u64).should eq(10_u64)
  end

  it "supports v2 streaming ingest set chunks" do
    cluster = Karma::Cluster.new
    Karma::Commands.call({v: 2, op: "counter.increment", series: "links", key: 42_u64, bucket: 20260505_u64, value: 10_u64}.to_json, cluster)

    Karma::Commands.call({v: 2, op: "ingest.begin", mode: "set", stream_id: "stream-set"}.to_json, cluster)
    response = Karma::Commands.call({
      v:         2,
      op:        "ingest.chunk",
      stream_id: "stream-set",
      series:    "links",
      chunk_seq: 1_u64,
      items:     [[42_u64, 20260505_u64, 3_u64], [43_u64, 20260505_u64, 0_u64]],
    }.to_json, cluster)
    parsed = parse_response(response)

    parsed["success"].as_bool.should be_true
    cluster.get("links").sum(42_u64).should eq(3_u64)
    cluster.get("links").sum(43_u64).should eq(0_u64)
  end

  it "supports v2 streaming ingest replace_series with atomic swap on commit" do
    cluster = Karma::Cluster.new
    Karma::Commands.call({v: 2, op: "counter.increment", series: "links", key: 1_u64, bucket: 20260505_u64, value: 99_u64}.to_json, cluster)

    Karma::Commands.call({v: 2, op: "ingest.begin", mode: "replace_series", stream_id: "stream-replace"}.to_json, cluster)
    chunk = parse_response(Karma::Commands.call({
      v:         2,
      op:        "ingest.chunk",
      stream_id: "stream-replace",
      series:    "links",
      chunk_seq: 1_u64,
      items:     [[2_u64, 20260505_u64, 5_u64]],
    }.to_json, cluster))

    chunk["success"].as_bool.should be_true
    cluster.get("links").sum(1_u64).should eq(99_u64)
    cluster.get("links").sum(2_u64).should eq(0_u64)

    commit = parse_response(Karma::Commands.call({v: 2, op: "ingest.commit", stream_id: "stream-replace"}.to_json, cluster))
    commit["success"].as_bool.should be_true
    cluster.get("links").sum(1_u64).should eq(0_u64)
    cluster.get("links").sum(2_u64).should eq(5_u64)
  end

  it "rejects changing series inside one ingest stream" do
    cluster = Karma::Cluster.new

    Karma::Commands.call({v: 2, op: "ingest.begin", mode: "add", stream_id: "stream-series"}.to_json, cluster)
    Karma::Commands.call({
      v:         2,
      op:        "ingest.chunk",
      stream_id: "stream-series",
      series:    "links",
      chunk_seq: 1_u64,
      items:     [[42_u64, 20260505_u64, 10_u64]],
    }.to_json, cluster)
    response = Karma::Commands.call({
      v:         2,
      op:        "ingest.chunk",
      stream_id: "stream-series",
      series:    "other",
      chunk_seq: 2_u64,
      items:     [[42_u64, 20260505_u64, 10_u64]],
    }.to_json, cluster)
    parsed = parse_response(response)

    parsed["success"].as_bool.should be_false
    parsed["error_code"].as_s.should eq("validation_error")
    cluster.trees.has_key?("other").should be_false
  end

  it "rejects out-of-order v2 streaming ingest chunks before applying them" do
    cluster = Karma::Cluster.new

    Karma::Commands.call({v: 2, op: "ingest.begin", mode: "add", stream_id: "stream-order"}.to_json, cluster)
    response = Karma::Commands.call({
      v:         2,
      op:        "ingest.chunk",
      stream_id: "stream-order",
      series:    "links",
      chunk_seq: 2_u64,
      items:     [[42_u64, 20260505_u64, 10_u64]],
    }.to_json, cluster)
    parsed = parse_response(response)

    parsed["success"].as_bool.should be_false
    parsed["error_code"].as_s.should eq("validation_error")
    cluster.trees.has_key?("links").should be_false
  end

  it "rejects unsupported v2 streaming ingest modes before persisting them" do
    cluster = Karma::Cluster.new

    response = Karma::Commands.call({
      v:         2,
      op:        "ingest.begin",
      mode:      "unknown",
      stream_id: "stream-unknown",
    }.to_json, cluster)
    parsed = parse_response(response)

    parsed["success"].as_bool.should be_false
    parsed["error_code"].as_s.should eq("validation_error")
  end

  it "supports v2 series delete_before retention" do
    cluster = Karma::Cluster.new

    Karma::Commands.call({v: 2, op: "counter.increment", tree: "links", key: 42_u64, date: 20260501_u64, value: 2_u64}.to_json, cluster)
    Karma::Commands.call({v: 2, op: "counter.increment", tree: "links", key: 42_u64, date: 20260503_u64, value: 3_u64}.to_json, cluster)

    response = Karma::Commands.call({
      v:      2,
      op:     "series.delete_before",
      series: "links",
      before: 20260503_u64,
    }.to_json, cluster)
    parsed = parse_response(response)

    parsed["success"].as_bool.should be_true
    cluster.get("links").sum(42_u64).should eq(3_u64)
    cluster.get("links").sum(42_u64, 20260501_u64, 20260501_u64).should eq(0_u64)
  end

  it "supports v2 series compact" do
    cluster = Karma::Cluster.new

    Karma::Commands.call({v: 2, op: "counter.increment", tree: "links", key: 42_u64, date: 20260501_u64, value: 1_u64}.to_json, cluster)
    Karma::Commands.call({v: 2, op: "counter.decrement", tree: "links", key: 42_u64, date: 20260501_u64, value: 1_u64}.to_json, cluster)
    cluster.key_count.should eq(1)

    response = Karma::Commands.call({v: 2, op: "series.compact", series: "links"}.to_json, cluster)
    parsed = parse_response(response)

    parsed["success"].as_bool.should be_true
    cluster.key_count.should eq(0)
  end

  it "supports v2 system compact" do
    cluster = Karma::Cluster.new

    Karma::Commands.call({v: 2, op: "counter.increment", tree: "links", key: 42_u64, date: 20260501_u64, value: 1_u64}.to_json, cluster)
    Karma::Commands.call({v: 2, op: "counter.decrement", tree: "links", key: 42_u64, date: 20260501_u64, value: 1_u64}.to_json, cluster)

    Karma::Commands.call({v: 2, op: "system.compact"}.to_json, cluster)

    cluster.key_count.should eq(0)
  end

  it "supports v2 series aliases with ISO date buckets" do
    cluster = Karma::Cluster.new

    Karma::Commands.call({
      v:           2,
      op:          "series.increment",
      series:      "links",
      key:         42_u64,
      bucket:      "2026-05-05",
      granularity: "day",
      value:       4_u64,
    }.to_json, cluster)

    cluster.get("links").sum(42_u64, 20260505_u64, 20260505_u64).should eq(4_u64)
  end

  it "supports v2 tree info" do
    cluster = Karma::Cluster.new

    Karma::Commands.call({v: 2, op: "counter.increment", tree: "links", key: 42_u64, date: 20260505_u64, value: 4_u64}.to_json, cluster)
    response = Karma::Commands.call({v: 2, op: "tree.info", tree: "links"}.to_json, cluster)
    parsed = parse_response(response)
    info = parsed["response"]

    parsed["protocol_version"].as_i.should eq(2)
    info["tree"].as_s.should eq("links")
    info["key_count"].as_i.should eq(1)
    info["bucket_count"].as_i.should eq(1)
    info["total"].as_i.should eq(4)
  end

  it "supports v2 tree keys pagination" do
    cluster = Karma::Cluster.new

    [10_u64, 20_u64, 30_u64].each do |key|
      Karma::Commands.call({v: 2, op: "counter.increment", tree: "links", key: key, date: 20260505_u64, value: key}.to_json, cluster)
    end

    first = parse_response(Karma::Commands.call({v: 2, op: "tree.keys", tree: "links", limit: 2}.to_json, cluster))["response"]
    first["keys"].as_a.map { |item| item["key"].as_i }.should eq([10, 20])
    first["next_cursor"].as_i.should eq(20)

    second = parse_response(Karma::Commands.call({v: 2, op: "tree.keys", tree: "links", limit: 2, cursor: first["next_cursor"].as_i}.to_json, cluster))["response"]
    second["keys"].as_a.map { |item| item["key"].as_i }.should eq([30])
    second["next_cursor"].raw.should be_nil
  end

  it "supports v2 tree summary" do
    cluster = Karma::Cluster.new

    Karma::Commands.call({v: 2, op: "counter.increment", tree: "links", key: 42_u64, date: 20260501_u64, value: 2_u64}.to_json, cluster)
    Karma::Commands.call({v: 2, op: "counter.increment", tree: "links", key: 43_u64, date: 20260503_u64, value: 7_u64}.to_json, cluster)

    total = parse_response(Karma::Commands.call({v: 2, op: "tree.summary", tree: "links"}.to_json, cluster))["response"]
    total["total"].as_i.should eq(9)
    total["active_keys"].as_i.should eq(2)

    ranged = parse_response(Karma::Commands.call({
      v:     2,
      op:    "tree.summary",
      tree:  "links",
      range: {from: 20260501_u64, to: 20260502_u64},
    }.to_json, cluster))["response"]
    ranged["total"].as_i.should eq(2)
    ranged["active_keys"].as_i.should eq(1)
    ranged["bucket_count"].as_i.should eq(1)
  end

  it "supports v2 tree top" do
    cluster = Karma::Cluster.new

    Karma::Commands.call({v: 2, op: "counter.increment", tree: "links", key: 42_u64, date: 20260501_u64, value: 2_u64}.to_json, cluster)
    Karma::Commands.call({v: 2, op: "counter.increment", tree: "links", key: 43_u64, date: 20260501_u64, value: 7_u64}.to_json, cluster)
    Karma::Commands.call({v: 2, op: "counter.increment", tree: "links", key: 44_u64, date: 20260503_u64, value: 100_u64}.to_json, cluster)

    response = Karma::Commands.call({
      v:     2,
      op:    "tree.top",
      tree:  "links",
      limit: 2,
      range: {from: 20260501_u64, to: 20260502_u64},
    }.to_json, cluster)
    items = parse_response(response)["response"]["items"].as_a

    items.map { |item| item["key"].as_i }.should eq([43, 42])
    items.map { |item| item["value"].as_i }.should eq([7, 2])
  end

  it "times out expensive tree-level reads" do
    Karma.configure { |c| c.query_timeout_ms = 1 }
    cluster = Karma::Cluster.new
    cluster.pick("links") do |tree|
      50_000.times do |index|
        tree.increment((index + 1).to_u64, 20260505_u64, 1_u64)
      end
    end

    response = Karma::Commands.call({
      v:    2,
      op:   "tree.summary",
      tree: "links",
    }.to_json, cluster)
    parsed = parse_response(response)

    parsed["success"].as_bool.should be_false
    parsed["error_code"].as_s.should eq("query_timeout")
  ensure
    Karma.configure { |c| c.query_timeout_ms = 1_000 }
  end

  it "enforces v2 tree read limits" do
    cluster = Karma::Cluster.new
    Karma::Commands.call({v: 2, op: "tree.create", tree: "links"}.to_json, cluster)

    bad_limit = parse_response(Karma::Commands.call({v: 2, op: "tree.keys", tree: "links", limit: 10_001}.to_json, cluster))
    bad_limit["success"].as_bool.should be_false
    bad_limit["error_code"].as_s.should eq("validation_error")

    bad_range = parse_response(Karma::Commands.call({
      v:     2,
      op:    "tree.summary",
      tree:  "links",
      range: {from: 20250101_u64, to: 20270101_u64},
    }.to_json, cluster))
    bad_range["success"].as_bool.should be_false
    bad_range["error_code"].as_s.should eq("validation_error")
  end

  it "returns v2 validation errors" do
    cluster = Karma::Cluster.new

    response = Karma::Commands.call({v: 2, op: "counter.sum", tree: "links"}.to_json, cluster)
    parsed = parse_response(response)

    parsed["protocol_version"].as_i.should eq(2)
    parsed["success"].as_bool.should be_false
    parsed["error_code"].as_s.should eq("validation_error")
    parsed["response"].as_s.should eq("Field key is required")
  end

  it "authenticates v2 requests" do
    Karma.configure { |c| c.auth_token = "secret" }
    cluster = Karma::Cluster.new

    unauthorized = parse_response(Karma::Commands.call({v: 2, op: "system.ping"}.to_json, cluster))
    unauthorized["protocol_version"].as_i.should eq(2)
    unauthorized["success"].as_bool.should be_false
    unauthorized["error_code"].as_s.should eq("unauthorized")
    parsed = parse_response(Karma::Commands.call({v: 2, op: "system.ping", token: "secret"}.to_json, cluster))

    parsed["protocol_version"].as_i.should eq(2)
    parsed["success"].as_bool.should be_true
  ensure
    Karma.configure do |c|
      c.auth_token = nil
      c.read_auth_token = nil
    end
  end
end
