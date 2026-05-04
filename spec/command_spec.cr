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
end
