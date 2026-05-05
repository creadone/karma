require "file_utils"
require "json"
require "option_parser"

require "../src/karma"

alias BenchmarkResult = NamedTuple(
  name: String,
  operations: Int64,
  requests: Int32,
  duration_ms: Float64,
  per_second: Float64,
  latency_p50_ms: Float64,
  latency_p95_ms: Float64,
)

sizes = [10_000, 50_000, 100_000]
bucket_count = 7
batch_size = 1_000
single_rounds = 1_000
read_rounds = 100
series = "links"
first_bucket = 20260501_u64
wal = false
wal_fsync = false
base_dir = File.join(Dir.tempdir, "karma_volume_load_test_#{Process.pid}")
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

def parse_sizes(value : String) : Array(Int32)
  value.split(",").map do |part|
    size = part.strip.to_i
    raise "sizes must contain positive integers" unless size > 0
    size
  end
end

OptionParser.parse do |parser|
  parser.banner = "Usage: crystal run scripts/volume_load_test.cr -- [options]"

  parser.on("--sizes=list", "Comma-separated key counts (default: #{sizes.join(",")})") { |value| sizes = parse_sizes(value) }
  parser.on("--bucket-count=count", "Buckets per key (default: #{bucket_count})") { |value| bucket_count = value.to_i }
  parser.on("--batch-size=count", "Items/keys per batch request (default: #{batch_size})") { |value| batch_size = value.to_i }
  parser.on("--single-rounds=count", "Single read/write rounds per size (default: #{single_rounds})") { |value| single_rounds = value.to_i }
  parser.on("--read-rounds=count", "Batch read rounds per size (default: #{read_rounds})") { |value| read_rounds = value.to_i }
  parser.on("--series=name", "Series name (default: #{series})") { |value| series = value }
  parser.on("--first-bucket=yyyymmdd", "First bucket date (default: #{first_bucket})") { |value| first_bucket = value.to_u64 }
  parser.on("--wal=flag", "Enable WAL during the test (default: #{wal})") { |value| wal = bool_flag(value) }
  parser.on("--wal-fsync=flag", "Fsync WAL writes (default: #{wal_fsync})") { |value| wal_fsync = bool_flag(value) }
  parser.on("--base-dir=path", "Base temp data directory (default: temp dir)") { |value| base_dir = value }
  parser.on("--json", "Print JSON output") { json_output = true }
  parser.on("-h", "--help", "Show this help") do
    puts parser
    exit
  end
end

raise "bucket-count must be greater than 0" unless bucket_count > 0
raise "batch-size must be greater than 0" unless batch_size > 0
raise "single-rounds must be >= 0" unless single_rounds >= 0
raise "read-rounds must be >= 0" unless read_rounds >= 0

def call!(cluster : Karma::Cluster, payload)
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

def result(name : String, operations : Int64, latencies : Array(Float64), duration_ms : Float64) : BenchmarkResult
  sorted = latencies.sort
  {
    name:           name,
    operations:     operations,
    requests:       latencies.size,
    duration_ms:    duration_ms,
    per_second:     duration_ms > 0.0 ? operations.to_f / (duration_ms / 1000.0) : 0.0,
    latency_p50_ms: percentile(sorted, 0.50),
    latency_p95_ms: percentile(sorted, 0.95),
  }
end

def benchmark(name : String, operations : Int64, &)
  latencies = [] of Float64
  started = Time.monotonic
  yield latencies
  result(name, operations, latencies, (Time.monotonic - started).total_milliseconds)
end

def batch_keys(round : Int32, keys : Int32, batch_size : Int32) : Array(UInt64)
  read_size = Math.min(batch_size, keys)
  offset = (round * read_size) % keys
  Array(UInt64).new(read_size) do |index|
    ((offset + index) % keys + 1).to_u64
  end
end

def data_file_bytes(dump_dir : String) : Int64
  Dir.glob(File.join(dump_dir, "*")).sum(0_i64) do |path|
    File.file?(path) ? File.size(path) : 0_i64
  end
end

def snapshot_bytes(dump_dir : String) : Int64
  Dir.glob(File.join(dump_dir, "*.tree")).sum(0_i64) { |path| File.size(path) }
end

def wal_bytes(dump_dir : String) : Int64
  path = Karma::Wal.path(dump_dir)
  File.exists?(path) ? File.size(path) : 0_i64
end

def seed_data!(cluster : Karma::Cluster, series : String, keys : Int32, bucket_count : Int32, first_bucket : UInt64, batch_size : Int32)
  data_points = keys.to_i64 * bucket_count.to_i64
  benchmark("seed.series.batch_add", data_points) do |latencies|
    items = [] of Tuple(UInt64, UInt64, UInt64)

    (1..keys).each do |key|
      bucket_count.times do |bucket_offset|
        items << {key.to_u64, first_bucket + bucket_offset.to_u64, 1_u64}
        next unless items.size >= batch_size

        started = Time.monotonic
        call!(cluster, {v: 2, op: "series.batch_add", series: series, items: items.dup})
        latencies << (Time.monotonic - started).total_milliseconds
        items.clear
      end
    end

    unless items.empty?
      started = Time.monotonic
      call!(cluster, {v: 2, op: "series.batch_add", series: series, items: items})
      latencies << (Time.monotonic - started).total_milliseconds
    end
  end
end

FileUtils.rm_rf(base_dir)
Dir.mkdir_p(base_dir)

results = [] of NamedTuple(
  keys: Int32,
  bucket_count: Int32,
  data_points: Int64,
  memory_bytes: Int64,
  wal_bytes_before_snapshot: Int64,
  snapshot_bytes: Int64,
  data_file_bytes_after_snapshot: Int64,
  seed: BenchmarkResult,
  single_sum: BenchmarkResult,
  single_increment_existing: BenchmarkResult,
  counter_batch_sum: BenchmarkResult,
  tree_summary: BenchmarkResult,
  snapshot_create_all: BenchmarkResult,
  restore_with_wal: BenchmarkResult,
)

begin
  sizes.each do |keys|
    dump_dir = File.join(base_dir, "keys_#{keys}")
    FileUtils.rm_rf(dump_dir)
    Dir.mkdir_p(dump_dir)

    Karma.configure do |config|
      config.dump_dir = dump_dir
      config.restore = false
      config.log = false
      config.wal = wal
      config.wal_fsync = wal_fsync
      config.query_timeout_ms = 0
      config.max_request_bytes = 64 * 1024 * 1024
      config.max_response_bytes = 64 * 1024 * 1024
    end

    cluster = Karma::Cluster.new
    data_points = keys.to_i64 * bucket_count.to_i64
    last_bucket = first_bucket + bucket_count.to_u64 - 1_u64

    seed_result = seed_data!(cluster, series, keys, bucket_count, first_bucket, batch_size)

    single_sum = benchmark("single_sum_existing", single_rounds.to_i64) do |latencies|
      single_rounds.times do |index|
        key = (index % keys + 1).to_u64
        started = Time.monotonic
        call!(cluster, {v: 2, op: "counter.sum", series: series, key: key})
        latencies << (Time.monotonic - started).total_milliseconds
      end
    end

    single_increment = benchmark("single_increment_existing", single_rounds.to_i64) do |latencies|
      single_rounds.times do |index|
        key = (index % keys + 1).to_u64
        started = Time.monotonic
        call!(cluster, {v: 2, op: "counter.increment", series: series, key: key, bucket: last_bucket, value: 1_u64})
        latencies << (Time.monotonic - started).total_milliseconds
      end
    end

    read_size = Math.min(batch_size, keys)
    batch_sum = benchmark("counter.batch_sum_existing", read_rounds.to_i64 * read_size.to_i64) do |latencies|
      read_rounds.times do |round|
        started = Time.monotonic
        call!(cluster, {v: 2, op: "counter.batch_sum", series: series, keys: batch_keys(round, keys, batch_size)})
        latencies << (Time.monotonic - started).total_milliseconds
      end
    end

    tree_summary = benchmark("tree.summary_full_range", keys.to_i64) do |latencies|
      started = Time.monotonic
      call!(cluster, {v: 2, op: "tree.summary", series: series, range: {from: first_bucket, to: last_bucket}})
      latencies << (Time.monotonic - started).total_milliseconds
    end

    GC.collect
    memory_bytes = GC.stats.heap_size.to_i64
    wal_before_snapshot = wal_bytes(dump_dir)

    snapshot = benchmark("snapshot.create_all", data_points) do |latencies|
      started = Time.monotonic
      call!(cluster, {v: 2, op: "snapshot.create_all"})
      latencies << (Time.monotonic - started).total_milliseconds
    end

    snapshot_size = snapshot_bytes(dump_dir)
    data_files_size = data_file_bytes(dump_dir)

    restore = benchmark("restore_with_wal", data_points) do |latencies|
      started = Time.monotonic
      restored = Karma::Cluster.restore_with_wal(dump_dir)
      raise "restored key count mismatch: #{restored.key_count} != #{keys}" unless restored.key_count == keys
      latencies << (Time.monotonic - started).total_milliseconds
    end

    results << {
      keys:                           keys,
      bucket_count:                   bucket_count,
      data_points:                    data_points,
      memory_bytes:                   memory_bytes,
      wal_bytes_before_snapshot:      wal_before_snapshot,
      snapshot_bytes:                 snapshot_size,
      data_file_bytes_after_snapshot: data_files_size,
      seed:                           seed_result,
      single_sum:                     single_sum,
      single_increment_existing:      single_increment,
      counter_batch_sum:              batch_sum,
      tree_summary:                   tree_summary,
      snapshot_create_all:            snapshot,
      restore_with_wal:               restore,
    }
  end
ensure
  FileUtils.rm_rf(base_dir)
end

if json_output
  puts({
    sizes:         sizes,
    bucket_count:  bucket_count,
    batch_size:    batch_size,
    single_rounds: single_rounds,
    read_rounds:   read_rounds,
    series:        series,
    first_bucket:  first_bucket,
    wal:           wal,
    wal_fsync:     wal_fsync,
    results:       results,
  }.to_json)
else
  puts "Karma volume load test"
  puts "sizes=#{sizes.join(",")} bucket_count=#{bucket_count} batch_size=#{batch_size} single_rounds=#{single_rounds} read_rounds=#{read_rounds} wal=#{wal} wal_fsync=#{wal_fsync}"
  puts "keys data_points memory_mb snapshot_mb seed_items_per_sec single_sum_ops_sec single_increment_ops_sec batch_sum_keys_per_sec batch_sum_p95_ms summary_ms snapshot_ms restore_ms"
  results.each do |entry|
    puts [
      entry[:keys],
      entry[:data_points],
      (entry[:memory_bytes].to_f / 1024.0 / 1024.0).round(2),
      (entry[:snapshot_bytes].to_f / 1024.0 / 1024.0).round(2),
      entry[:seed][:per_second].round(2),
      entry[:single_sum][:per_second].round(2),
      entry[:single_increment_existing][:per_second].round(2),
      entry[:counter_batch_sum][:per_second].round(2),
      entry[:counter_batch_sum][:latency_p95_ms].round(4),
      entry[:tree_summary][:duration_ms].round(2),
      entry[:snapshot_create_all][:duration_ms].round(2),
      entry[:restore_with_wal][:duration_ms].round(2),
    ].join(" ")
  end
end
