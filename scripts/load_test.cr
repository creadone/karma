require "json"
require "option_parser"

require "../src/config"
require "../src/protocol"
require "../src/time_series"
require "../src/ingest"
require "../src/query_deadline"
require "../src/cluster"
require "../src/state"
require "../src/backup"
require "../src/wal"
require "../src/log"
require "../src/operations"
require "../src/command"

keys = 10_000
batch_size = 1_000
single_rounds = 10_000
read_rounds = 100
series = "links"
bucket = 20260505_u64
json_output = false

OptionParser.parse do |parser|
  parser.banner = "Usage: crystal run scripts/load_test.cr -- [options]"

  parser.on("--keys=count", "Number of distinct keys (default: #{keys})") { |value| keys = value.to_i }
  parser.on("--batch-size=count", "Keys/items per batch request (default: #{batch_size})") { |value| batch_size = value.to_i }
  parser.on("--single-rounds=count", "Single increment/sum rounds (default: #{single_rounds})") { |value| single_rounds = value.to_i }
  parser.on("--read-rounds=count", "Batch sum rounds (default: #{read_rounds})") { |value| read_rounds = value.to_i }
  parser.on("--series=name", "Series name (default: #{series})") { |value| series = value }
  parser.on("--bucket=yyyymmdd", "Bucket date (default: #{bucket})") { |value| bucket = value.to_u64 }
  parser.on("--json", "Print JSON output") { json_output = true }
  parser.on("-h", "--help", "Show this help") do
    puts parser
    exit
  end
end

raise "keys must be greater than 0" unless keys > 0
raise "batch-size must be greater than 0" unless batch_size > 0
raise "single-rounds must be >= 0" unless single_rounds >= 0
raise "read-rounds must be >= 0" unless read_rounds >= 0

Karma.configure do |config|
  config.log = false
  config.wal = false
  config.query_timeout_ms = 0
  config.max_request_bytes = 64 * 1024 * 1024
  config.max_response_bytes = 64 * 1024 * 1024
end

cluster = Karma::Cluster.new

def call!(cluster, payload)
  response = Karma::Commands.call(payload.to_json, cluster)
  parsed = JSON.parse(response)
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

def benchmark(name : String, operations : Int32 | Int64 | UInt64, &)
  latencies = [] of Float64
  started = Time.monotonic
  yield latencies
  duration_ms = (Time.monotonic - started).total_milliseconds
  sorted = latencies.sort
  operations_count = operations.to_f
  per_second = duration_ms > 0.0 ? operations_count / (duration_ms / 1000.0) : 0.0
  {
    name:           name,
    operations:     operations,
    requests:       latencies.size,
    duration_ms:    duration_ms,
    per_second:     per_second,
    latency_p50_ms: percentile(sorted, 0.50),
    latency_p95_ms: percentile(sorted, 0.95),
  }
end

key_values = (1_u64..keys.to_u64).to_a

results = [] of NamedTuple(
  name: String,
  operations: Int32 | Int64 | UInt64,
  requests: Int32,
  duration_ms: Float64,
  per_second: Float64,
  latency_p50_ms: Float64,
  latency_p95_ms: Float64,
)

results << benchmark("single_increment", single_rounds) do |latencies|
  single_rounds.times do |index|
    key = (index % keys + 1).to_u64
    started = Time.monotonic
    call!(cluster, {v: 2, op: "counter.increment", series: series, key: key, bucket: bucket, value: 1_u64})
    latencies << (Time.monotonic - started).total_milliseconds
  end
end

results << benchmark("single_sum", single_rounds) do |latencies|
  single_rounds.times do |index|
    key = (index % keys + 1).to_u64
    started = Time.monotonic
    call!(cluster, {v: 2, op: "counter.sum", series: series, key: key})
    latencies << (Time.monotonic - started).total_milliseconds
  end
end

items = key_values.map { |key| [key, bucket, 1_u64] }
chunks = items.each_slice(batch_size).to_a

results << benchmark("series.batch_add", items.size) do |latencies|
  chunks.each do |chunk|
    started = Time.monotonic
    call!(cluster, {v: 2, op: "series.batch_add", series: series, items: chunk})
    latencies << (Time.monotonic - started).total_milliseconds
  end
end

batch_operations = read_rounds.to_i64 * batch_size
results << benchmark("counter.batch_sum", batch_operations) do |latencies|
  read_rounds.times do |round|
    offset = (round * batch_size) % keys
    batch = Array(UInt64).new(batch_size) do |index|
      ((offset + index) % keys + 1).to_u64
    end

    started = Time.monotonic
    call!(cluster, {v: 2, op: "counter.batch_sum", series: series, keys: batch})
    latencies << (Time.monotonic - started).total_milliseconds
  end
end

if json_output
  puts({
    keys:          keys,
    batch_size:    batch_size,
    single_rounds: single_rounds,
    read_rounds:   read_rounds,
    series:        series,
    bucket:        bucket,
    results:       results,
  }.to_json)
else
  puts "Karma load test"
  puts "keys=#{keys} batch_size=#{batch_size} single_rounds=#{single_rounds} read_rounds=#{read_rounds}"
  results.each do |result|
    puts "#{result[:name]}: operations=#{result[:operations]} requests=#{result[:requests]} duration_ms=#{result[:duration_ms].round(2)} per_second=#{result[:per_second].round(2)} p50_ms=#{result[:latency_p50_ms].round(4)} p95_ms=#{result[:latency_p95_ms].round(4)}"
  end
end
