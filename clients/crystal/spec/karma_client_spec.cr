require "json"
require "socket"
require "spec"
require "../src/karma_client"

class KarmaClientTestServer
  getter port : Int32
  getter requests : Channel(JSON::Any)

  @fiber : Fiber

  def initialize(&@handler : JSON::Any -> Hash(String, JSON::Any))
    @requests = Channel(JSON::Any).new(100)
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.local_address.port
    @stopped = Channel(Nil).new
    @fiber = spawn accept_loop
  end

  def close : Nil
    @server.close
    @stopped.receive?
  end

  private def accept_loop : Nil
    while client = @server.accept?
      spawn handle_client(client)
    end
  rescue IO::Error
  ensure
    @stopped.send(nil)
  end

  private def handle_client(client : TCPSocket) : Nil
    while line = client.gets(chomp: true)
      request = JSON.parse(line)
      @requests.send(request)
      client << @handler.call(request).to_json << "\r\n"
      client.flush
    end
  rescue IO::Error
  ensure
    client.close
  end
end

private def success_response(value : JSON::Any, idempotent : Bool? = nil) : Hash(String, JSON::Any)
  response = {
    "protocol_version" => JSON::Any.new(2_i64),
    "success"          => JSON::Any.new(true),
    "response"         => value,
    "error_code"       => JSON::Any.new(nil),
  }
  response["idempotent"] = JSON::Any.new(idempotent) unless idempotent.nil?
  response
end

private def success_response(value, idempotent : Bool? = nil) : Hash(String, JSON::Any)
  success_response(json_any(value), idempotent)
end

private def error_response(code : String, message : String) : Hash(String, JSON::Any)
  {
    "protocol_version" => JSON::Any.new(2_i64),
    "success"          => JSON::Any.new(false),
    "response"         => JSON::Any.new(message),
    "error_code"       => JSON::Any.new(code),
  }
end

private def json_any(value : JSON::Any) : JSON::Any
  value
end

private def json_any(value : Nil) : JSON::Any
  JSON::Any.new(nil)
end

private def json_any(value : Bool) : JSON::Any
  JSON::Any.new(value)
end

private def json_any(value : Int) : JSON::Any
  JSON::Any.new(value.to_i64)
end

private def json_any(value : String) : JSON::Any
  JSON::Any.new(value)
end

private def json_any(value : Array) : JSON::Any
  JSON::Any.new(value.map { |item| json_any(item) })
end

private def json_any(value : Hash) : JSON::Any
  hash = Hash(String, JSON::Any).new
  value.each { |key, item| hash[key.to_s] = json_any(item) }
  JSON::Any.new(hash)
end

describe KarmaClient::Client do
  server = nil.as(KarmaClientTestServer?)
  client = nil.as(KarmaClient::Client?)

  after_each do
    client.try(&.close)
    server.try(&.close)
    client = nil
    server = nil
    KarmaClient.close
  end

  it "records limit usage with v2 payload, token, bucket, and idempotency fields" do
    test_server = KarmaClientTestServer.new { |_request| success_response("OK") }
    server = test_server
    test_client = KarmaClient::Client.new(host: "127.0.0.1", port: test_server.port, token: "secret")
    client = test_client

    result = test_client.record_usage(
      "api_requests",
      subject_id: 42,
      amount: 3,
      day: Time.utc(2026, 5, 5),
      idempotency_key: "usage-event-1",
      fingerprint: "fp-1"
    )

    result.as_s.should eq("OK")
    request = test_server.requests.receive
    request["v"].as_i.should eq(2)
    request["op"].as_s.should eq("counter.increment")
    request["series"].as_s.should eq("api_requests")
    request["key"].as_i.should eq(42)
    request["bucket"].as_i.should eq(20260505)
    request["value"].as_i.should eq(3)
    request["token"].as_s.should eq("secret")
    request["idempotency_key"].as_s.should eq("usage-event-1")
    request["fingerprint"].as_s.should eq("fp-1")
  end

  it "reads one subject usage as UInt64" do
    test_server = KarmaClientTestServer.new { |_request| success_response(15) }
    server = test_server
    test_client = KarmaClient::Client.new(host: "127.0.0.1", port: test_server.port)
    client = test_client

    test_client.usage("api_requests", subject_id: 42, from: "2026-05-01", to: "2026-05-31").should eq(15_u64)

    request = test_server.requests.receive
    request["op"].as_s.should eq("counter.sum")
    request["range"]["from"].as_i.should eq(20260501)
    request["range"]["to"].as_i.should eq(20260531)
  end

  it "reads batch usage into a typed hash" do
    payload = [
      {"key" => 41, "value" => 10},
      {"key" => 42, "value" => 15},
    ]
    test_server = KarmaClientTestServer.new { |_request| success_response(payload) }
    server = test_server
    test_client = KarmaClient::Client.new(host: "127.0.0.1", port: test_server.port)
    client = test_client

    test_client.batch_usage("api_requests", [41, 42]).should eq({41_u64 => 10_u64, 42_u64 => 15_u64})

    request = test_server.requests.receive
    request["op"].as_s.should eq("counter.batch_sum")
    request["keys"].as_a.map(&.as_i).should eq([41, 42])
  end

  it "returns raw response envelopes for idempotent writes" do
    test_server = KarmaClientTestServer.new { |_request| success_response({"applied" => 1}, idempotent: true) }
    server = test_server
    test_client = KarmaClient::Client.new(host: "127.0.0.1", port: test_server.port)
    client = test_client

    response = test_client.request(
      "series.batch_add",
      series: "api_requests",
      items: [{42, 20260505, 10}],
      idempotency_key: "usage-event-1"
    )

    response.success?.should be_true
    response.idempotent?.should be_true

    request = test_server.requests.receive
    request["items"][0][0].as_i.should eq(42)
    request["idempotency_key"].as_s.should eq("usage-event-1")
  end

  it "maps server errors and preserves retriable policy" do
    test_server = KarmaClientTestServer.new { |_request| error_response("validation_error", "Field key is required") }
    server = test_server
    test_client = KarmaClient::Client.new(host: "127.0.0.1", port: test_server.port)
    client = test_client

    error = expect_raises(KarmaClient::ValidationError) do
      test_client.call("counter.sum", series: "api_requests")
    end

    error.code.should eq("validation_error")
    error.retriable?.should be_false
  end

  it "loads configuration from environment-compatible hashes" do
    config = KarmaClient::Configuration.from_env({
      "KARMA_URL"   => "tcp://127.0.0.1:18080?token=from-url",
      "KARMA_TOKEN" => "",
    })

    config.host.should eq("127.0.0.1")
    config.port.should eq(18_080)
    config.token.should eq("from-url")
  end
end
