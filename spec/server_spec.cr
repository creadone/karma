require "./spec_helper"

class FakeClient
  property read_timeout : Time::Span?
  property write_timeout : Time::Span?
  getter sent = [] of String

  def initialize(@messages : Array(String), @read_error : Exception? = nil, @write_error : Exception? = nil)
  end

  def gets(delimiter : Char, limit : Int32, chomp : Bool)
    raise @read_error.not_nil! unless @read_error.nil?

    @messages.shift?
  end

  def send(message : String)
    @sent << message
  end

  def <<(message : String)
    raise @write_error.not_nil! unless @write_error.nil?

    @sent << "" if @sent.empty?
    @sent[-1] += message
    self
  end

  def flush
  end
end

describe Karma::Server do
  it "rejects oversized requests" do
    Karma.configure do |c|
      c.max_request_bytes = 4
      c.read_timeout_seconds = 1
      c.write_timeout_seconds = 1
    end
    client = FakeClient.new(["12345"])

    Karma::ClientSession.new(client, Karma::Cluster.new).run

    parsed = parse_response(client.sent.first.strip)
    parsed["success"].as_bool.should be_false
    parsed["error_code"].as_s.should eq("request_too_large")
    client.read_timeout.should eq(1.second)
    client.write_timeout.should eq(1.second)
  ensure
    Karma.configure do |c|
      c.max_request_bytes = 4096
      c.read_timeout_seconds = 5
      c.write_timeout_seconds = 5
    end
  end

  it "treats client read timeout as a closed session" do
    client = FakeClient.new([] of String, IO::TimeoutError.new("Read timed out"))

    Karma::ClientSession.new(client, Karma::Cluster.new).run

    client.sent.should be_empty
  end

  it "treats client write errors as a closed session" do
    client = FakeClient.new(
      [{v: 2, op: "system.ping"}.to_json],
      nil,
      IO::Error.new("Broken pipe")
    )

    Karma::ClientSession.new(client, Karma::Cluster.new).run

    client.sent.should be_empty
  end
end
