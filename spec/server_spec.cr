require "./spec_helper"

class FakeClient
  property read_timeout : Time::Span?
  property write_timeout : Time::Span?
  getter sent = [] of String

  def initialize(@messages : Array(String))
  end

  def gets(delimiter : Char, limit : Int32, chomp : Bool)
    @messages.shift?
  end

  def send(message : String)
    @sent << message
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
end
