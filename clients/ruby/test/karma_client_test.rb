# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "socket"
require_relative "../lib/karma_client"

class KarmaClientTestServer
  attr_reader :port, :requests

  def initialize(&handler)
    @handler = handler
    @requests = Queue.new
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @client_threads = []
    @thread = Thread.new { accept_loop }
  end

  def close
    @server.close
    @thread.join(1)
    @client_threads.each { |thread| thread.join(1) }
  end

  private

  def accept_loop
    loop do
      socket = @server.accept
      @client_threads << Thread.new(socket) { |client| handle_client(client) }
    rescue IOError, Errno::EBADF
      break
    end
  end

  def handle_client(client)
    while (line = client.gets)
      request = JSON.parse(line)
      @requests << request
      response = @handler.call(request)
      client.write(JSON.generate(response))
      client.write("\r\n")
    end
  ensure
    client.close
  end
end

class KarmaClientTest < Minitest::Test
  def teardown
    @client&.close
    @server&.close
    KarmaClient.close
  end

  def test_increment_uses_v2_payload_with_token_and_normalized_bucket
    @server = KarmaClientTestServer.new do |_request|
      success_response("OK")
    end
    @client = KarmaClient::Client.new(host: "127.0.0.1", port: @server.port, token: "secret")

    assert_equal "OK", @client.increment(series: "links", key: 42, bucket: Date.new(2026, 5, 5), value: 3)

    request = @server.requests.pop
    assert_equal 2, request["v"]
    assert_equal "counter.increment", request["op"]
    assert_equal "links", request["series"]
    assert_equal 42, request["key"]
    assert_equal 20260505, request["bucket"]
    assert_equal 3, request["value"]
    assert_equal "secret", request["token"]
  end

  def test_batch_sum_returns_response_value
    @server = KarmaClientTestServer.new do |_request|
      success_response([{ "key" => 41, "value" => 10 }, { "key" => 42, "value" => 15 }])
    end
    @client = KarmaClient::Client.new(host: "127.0.0.1", port: @server.port)

    result = @client.batch_sum(series: "links", keys: [41, 42], from: "2026-05-01", to: "2026-05-31")

    assert_equal [{ "key" => 41, "value" => 10 }, { "key" => 42, "value" => 15 }], result
    request = @server.requests.pop
    assert_equal({ "from" => 20260501, "to" => 20260531 }, request["range"])
  end

  def test_server_error_mapping_preserves_code_and_retriable_policy
    @server = KarmaClientTestServer.new do |_request|
      error_response("validation_error", "Field key is required")
    end
    @client = KarmaClient::Client.new(host: "127.0.0.1", port: @server.port)

    error = assert_raises(KarmaClient::ValidationError) do
      @client.call("counter.sum", series: "links")
    end

    assert_equal "validation_error", error.code
    refute error.retriable?
  end

  def test_request_returns_raw_error_response_without_raising_server_error
    @server = KarmaClientTestServer.new do |_request|
      error_response("not_found", "Tree \"links\" not found")
    end
    @client = KarmaClient::Client.new(host: "127.0.0.1", port: @server.port)

    response = @client.request("counter.sum", series: "links", key: 42)

    refute response.success?
    assert_equal "not_found", response.error_code
    assert_equal "Tree \"links\" not found", response.value
  end

  def test_pool_reuses_configured_clients
    @server = KarmaClientTestServer.new do |_request|
      success_response("pong")
    end

    KarmaClient.configure do |config|
      config.host = "127.0.0.1"
      config.port = @server.port
      config.pool_size = 1
      config.pool_timeout = 0.2
    end

    result = KarmaClient.with_client(&:ping)

    assert_equal "pong", result
  end

  def test_client_side_input_validation
    @client = KarmaClient::Client.new(host: "127.0.0.1", port: 1)

    assert_raises(KarmaClient::InputError) do
      @client.increment(series: "", key: 42)
    end

    assert_raises(KarmaClient::InputError) do
      @client.sum(series: "links", key: 42, from: "2026-05-01")
    end
  end

  def test_configuration_preserves_token_from_url_when_token_env_is_absent
    config = KarmaClient::Configuration.from_env(
      "KARMA_URL" => "tcp://127.0.0.1:18080?token=from-url",
      "KARMA_TOKEN" => ""
    )

    assert_equal "127.0.0.1", config.host
    assert_equal 18_080, config.port
    assert_equal "from-url", config.token
  end

  private

  def success_response(value)
    {
      "protocol_version" => 2,
      "success" => true,
      "response" => value,
      "error_code" => nil
    }
  end

  def error_response(code, message)
    {
      "protocol_version" => 2,
      "success" => false,
      "response" => message,
      "error_code" => code
    }
  end
end
