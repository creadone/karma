require "file_utils"
require "json"
require "option_parser"
require "socket"

require "../src/karma"

host = "127.0.0.1"
port = 19_090
clients = 4
keys = 10_000
batch_size = 1_000
single_rounds = 10_000
read_rounds = 100
series = "links"
bucket = 20260505_u64
wal = true
wal_fsync = false
dump_dir = File.join(Dir.tempdir, "karma_tcp_load_test_#{Process.pid}")
json_output = false

def bool_flag(value : String) : Bool
  case value
  when "true"
    true
  when "false"
    false
  else
    raise "Expected true or false, got #{value}"
  end
end

OptionParser.parse do |parser|
  parser.banner = "Usage: crystal run scripts/tcp_load_test.cr -- [options]"

  parser.on("--host=host", "Host to bind/connect (default: #{host})") { |value| host = value }
  parser.on("--port=port", "Port to bind/connect (default: #{port})") { |value| port = value.to_i }
  parser.on("--clients=count", "Concurrent TCP clients (default: #{clients})") { |value| clients = value.to_i }
  parser.on("--keys=count", "Number of distinct keys (default: #{keys})") { |value| keys = value.to_i }
  parser.on("--batch-size=count", "Keys/items per batch request (default: #{batch_size})") { |value| batch_size = value.to_i }
  parser.on("--single-rounds=count", "Single increment/sum rounds (default: #{single_rounds})") { |value| single_rounds = value.to_i }
  parser.on("--read-rounds=count", "Batch sum rounds (default: #{read_rounds})") { |value| read_rounds = value.to_i }
  parser.on("--series=name", "Series name (default: #{series})") { |value| series = value }
  parser.on("--bucket=yyyymmdd", "Bucket date (default: #{bucket})") { |value| bucket = value.to_u64 }
  parser.on("--wal=flag", "Enable WAL (default: #{wal})") { |value| wal = bool_flag(value) }
  parser.on("--wal-fsync=flag", "Fsync WAL writes (default: #{wal_fsync})") { |value| wal_fsync = bool_flag(value) }
  parser.on("--dump-dir=path", "Data directory (default: temp dir)") { |value| dump_dir = value }
  parser.on("--json", "Print JSON output") { json_output = true }
  parser.on("-h", "--help", "Show this help") do
    puts parser
    exit
  end
end

raise "clients must be greater than 0" unless clients > 0
raise "keys must be greater than 0" unless keys > 0
raise "batch-size must be greater than 0" unless batch_size > 0
raise "single-rounds must be >= 0" unless single_rounds >= 0
raise "read-rounds must be >= 0" unless read_rounds >= 0

Karma.configure do |config|
  config.host = host
  config.port = port
  config.dump_dir = dump_dir
  config.restore = false
  config.log = false
  config.wal = wal
  config.wal_fsync = wal_fsync
  config.query_timeout_ms = 0
  config.max_request_bytes = 64 * 1024 * 1024
  config.max_response_bytes = 64 * 1024 * 1024
end

Dir.mkdir_p(dump_dir)
cluster = Karma::Cluster.new
server = Karma::Server.new(cluster)
spawn server.start!

def connect_with_retry(host : String, port : Int32) : TCPSocket
  last_error = nil
  100.times do
    begin
      return TCPSocket.new(host, port)
    rescue ex
      last_error = ex
      sleep 10.milliseconds
    end
  end

  raise last_error || "Cannot connect to #{host}:#{port}"
end

def request!(socket : TCPSocket, payload) : JSON::Any
  socket << payload.to_json << "\n"
  line = socket.gets || raise "Connection closed"
  parsed = JSON.parse(line)
  unless parsed["success"].as_bool
    raise "#{parsed["error_code"]}: #{parsed["response"]}"
  end
  parsed["response"]
end

def percentile(sorted : Array(Float64), percentile : Float64) : Float64
  return 0.0 if sorted.empty?

  index = ((sorted.size - 1) * percentile).round.to_i
  sorted[index]
end

def benchmark(name : String, operations : Int32 | Int64 | UInt64, clients : Int32, host : String, port : Int32, &block : Int32, TCPSocket, Array(Float64) ->)
  channel = Channel(NamedTuple(latencies: Array(Float64), error: String?)).new
  started = Time.monotonic

  clients.times do |client_index|
    spawn do
      latencies = [] of Float64
      socket = connect_with_retry(host, port)
      begin
        block.call(client_index, socket, latencies)
        channel.send({latencies: latencies, error: nil})
      rescue ex
        channel.send({latencies: latencies, error: ex.message || ex.class.name})
      ensure
        socket.close unless socket.closed?
      end
    end
  end

  all_latencies = [] of Float64
  errors = [] of String
  clients.times do
    result = channel.receive
    all_latencies.concat(result[:latencies])
    errors << result[:error].not_nil! unless result[:error].nil?
  end
  raise errors.join("; ") unless errors.empty?

  duration_ms = (Time.monotonic - started).total_milliseconds
  sorted = all_latencies.sort
  operations_count = operations.to_f
  per_second = duration_ms > 0.0 ? operations_count / (duration_ms / 1000.0) : 0.0
  {
    name:           name,
    operations:     operations,
    requests:       all_latencies.size,
    duration_ms:    duration_ms,
    per_second:     per_second,
    latency_p50_ms: percentile(sorted, 0.50),
    latency_p95_ms: percentile(sorted, 0.95),
  }
end

results = [] of NamedTuple(
  name: String,
  operations: Int32 | Int64 | UInt64,
  requests: Int32,
  duration_ms: Float64,
  per_second: Float64,
  latency_p50_ms: Float64,
  latency_p95_ms: Float64,
)

key_values = (1_u64..keys.to_u64).to_a
items = key_values.map { |key| [key, bucket, 1_u64] }
chunks = items.each_slice(batch_size).to_a

results << benchmark("tcp_single_increment", single_rounds, clients, host, port) do |client_index, socket, latencies|
  single_rounds.times do |index|
    next unless index % clients == client_index

    key = (index % keys + 1).to_u64
    started = Time.monotonic
    request!(socket, {v: 2, op: "counter.increment", series: series, key: key, bucket: bucket, value: 1_u64})
    latencies << (Time.monotonic - started).total_milliseconds
  end
end

results << benchmark("tcp_single_sum", single_rounds, clients, host, port) do |client_index, socket, latencies|
  single_rounds.times do |index|
    next unless index % clients == client_index

    key = (index % keys + 1).to_u64
    started = Time.monotonic
    request!(socket, {v: 2, op: "counter.sum", series: series, key: key})
    latencies << (Time.monotonic - started).total_milliseconds
  end
end

results << benchmark("tcp_series.batch_add", items.size, clients, host, port) do |client_index, socket, latencies|
  chunks.each_with_index do |chunk, index|
    next unless index % clients == client_index

    started = Time.monotonic
    request!(socket, {v: 2, op: "series.batch_add", series: series, items: chunk})
    latencies << (Time.monotonic - started).total_milliseconds
  end
end

batch_operations = read_rounds.to_i64 * batch_size
results << benchmark("tcp_counter.batch_sum", batch_operations, clients, host, port) do |client_index, socket, latencies|
  read_rounds.times do |round|
    next unless round % clients == client_index

    offset = (round * batch_size) % keys
    batch = Array(UInt64).new(batch_size) do |index|
      ((offset + index) % keys + 1).to_u64
    end

    started = Time.monotonic
    request!(socket, {v: 2, op: "counter.batch_sum", series: series, keys: batch})
    latencies << (Time.monotonic - started).total_milliseconds
  end
end

if json_output
  puts({
    host:          host,
    port:          port,
    clients:       clients,
    keys:          keys,
    batch_size:    batch_size,
    single_rounds: single_rounds,
    read_rounds:   read_rounds,
    series:        series,
    bucket:        bucket,
    wal:           wal,
    wal_fsync:     wal_fsync,
    dump_dir:      dump_dir,
    results:       results,
  }.to_json)
else
  puts "Karma TCP load test"
  puts "host=#{host} port=#{port} clients=#{clients} keys=#{keys} batch_size=#{batch_size} single_rounds=#{single_rounds} read_rounds=#{read_rounds} wal=#{wal} wal_fsync=#{wal_fsync}"
  results.each do |result|
    puts "#{result[:name]}: operations=#{result[:operations]} requests=#{result[:requests]} duration_ms=#{result[:duration_ms].round(2)} per_second=#{result[:per_second].round(2)} p50_ms=#{result[:latency_p50_ms].round(4)} p95_ms=#{result[:latency_p95_ms].round(4)}"
  end
end

FileUtils.rm_rf(dump_dir)
