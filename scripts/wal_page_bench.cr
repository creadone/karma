require "file_utils"
require "json"
require "option_parser"

require "../src/karma"

entries_count = 100_000
limit = 1_000
tail_rounds = 200
payload_bytes = 0
segment_bytes = 0
after_lsn_override : UInt64? = nil
compare_sidecar = false
skip_linear = false
skip_sequential = false
dump_dir = File.join(Dir.tempdir, "karma_wal_page_bench_#{Process.pid}")
keep_data = false
json_output = false

OptionParser.parse do |parser|
  parser.banner = "Usage: crystal run scripts/wal_page_bench.cr -- [options]"

  parser.on("--entries=count", "WAL entries to generate (default: #{entries_count})") { |value| entries_count = value.to_i }
  parser.on("--limit=count", "Entries per page (default: #{limit})") { |value| limit = value.to_i }
  parser.on("--tail-rounds=count", "Repeated tail page reads (default: #{tail_rounds})") { |value| tail_rounds = value.to_i }
  parser.on("--payload-bytes=count", "Extra bytes per WAL entry payload (default: #{payload_bytes})") { |value| payload_bytes = value.to_i }
  parser.on("--segment-bytes=count", "Generate WAL through Karma with rotation; 0 writes one WAL file directly (default: #{segment_bytes})") { |value| segment_bytes = value.to_i }
  parser.on("--after-lsn=lsn", "Read benchmark pages after this LSN; default targets the tail page") { |value| after_lsn_override = value.to_u64 }
  parser.on("--compare-sidecar", "For segmented WALs, also measure cold read after deleting sidecar indexes") { compare_sidecar = true }
  parser.on("--skip-linear", "Skip linear baseline scans for large WALs") { skip_linear = true }
  parser.on("--skip-sequential", "Skip sequential catch-up benchmarks") { skip_sequential = true }
  parser.on("--dump-dir=path", "Benchmark data directory (default: #{dump_dir})") { |value| dump_dir = value }
  parser.on("--keep-data", "Keep benchmark data directory after the run") { keep_data = true }
  parser.on("--json", "Print JSON output") { json_output = true }
  parser.on("-h", "--help", "Show this help") do
    puts parser
    exit
  end
end

raise "entries must be greater than 0" unless entries_count > 0
raise "limit must be greater than 0" unless limit > 0
raise "tail-rounds must be greater than 0" unless tail_rounds > 0
raise "payload-bytes must be >= 0" unless payload_bytes >= 0
raise "segment-bytes must be >= 0" unless segment_bytes >= 0
raise "after-lsn must be <= entries" if after_lsn_override && after_lsn_override.not_nil! > entries_count

Karma.configure do |config|
  config.log = false
  config.dump_dir = dump_dir
  config.wal = true
  config.wal_fsync = false
  config.wal_segment_bytes = segment_bytes
  config.max_request_bytes = 64 * 1024 * 1024
  config.max_response_bytes = 64 * 1024 * 1024
end

def percentile(sorted : Array(Float64), percentile : Float64) : Float64
  return 0.0 if sorted.empty?

  index = ((sorted.size - 1) * percentile).round.to_i
  sorted[index]
end

def result(name : String, operations : Int32 | Int64 | UInt64, requests : Int32, latencies : Array(Float64), duration_ms : Float64)
  sorted = latencies.sort
  {
    name:           name,
    operations:     operations,
    requests:       requests,
    duration_ms:    duration_ms,
    per_second:     duration_ms > 0.0 ? operations.to_f / (duration_ms / 1000.0) : 0.0,
    latency_p50_ms: percentile(sorted, 0.50),
    latency_p95_ms: percentile(sorted, 0.95),
  }
end

def benchmark(name : String, operations : Int32 | Int64 | UInt64, requests : Int32, &)
  latencies = [] of Float64
  started = Time.monotonic
  yield latencies
  duration_ms = (Time.monotonic - started).total_milliseconds
  result(name, operations, requests, latencies, duration_ms)
end

def current_rss_kb : Int64
  return 0_i64 unless LibC.getrusage(LibC::RUSAGE_SELF, out usage) == 0

  maxrss = usage.ru_maxrss.to_i64
  {% if flag?(:darwin) %}
    maxrss // 1024
  {% else %}
    maxrss
  {% end %}
rescue
  0_i64
end

def call!(cluster : Karma::Cluster, payload)
  response = Karma::Commands.call(payload.to_json, cluster)
  parsed = JSON.parse(response)
  unless parsed["success"].as_bool
    raise "#{parsed["error_code"]}: #{parsed["response"]}"
  end
  parsed["response"]
end

def write_wal(dump_dir : String, entries_count : Int32, payload_bytes : Int32) : Int64
  FileUtils.rm_rf(dump_dir)
  Dir.mkdir_p(dump_dir)

  padding = payload_bytes > 0 ? "x" * payload_bytes : nil
  File.open(Karma::Wal.path(dump_dir), "w") do |io|
    entries_count.times do |index|
      lsn = (index + 1).to_u64
      key = (index % 10_000 + 1).to_u64
      io << {
        v:     2,
        lsn:   lsn,
        entry: {
          v:     2,
          op:    "counter.increment",
          tree:  "links",
          key:   key,
          date:  20260505_u64,
          value: 1_u64,
          pad:   padding,
        },
      }.to_json << '\n'
    end
  end
  File.write(Karma::Wal.lsn_path(dump_dir), "#{entries_count}\n")
  File.size(Karma::Wal.path(dump_dir))
end

def generate_segmented_wal(dump_dir : String, entries_count : Int32, payload_bytes : Int32) : Int64
  FileUtils.rm_rf(dump_dir)
  Dir.mkdir_p(dump_dir)

  padding = payload_bytes > 0 ? "x" * payload_bytes : nil
  cluster = Karma::Cluster.new
  entries_count.times do |index|
    call!(cluster, {
      v:     2,
      op:    "counter.increment",
      tree:  "links",
      key:   (index % 10_000 + 1).to_u64,
      date:  20260505_u64,
      value: 1_u64,
      pad:   padding,
    })
  end
  Karma::Wal.bytes(dump_dir)
end

def write_benchmark_wal(dump_dir : String, entries_count : Int32, payload_bytes : Int32, segment_bytes : Int32) : Int64
  if segment_bytes > 0
    generate_segmented_wal(dump_dir, entries_count, payload_bytes)
  else
    write_wal(dump_dir, entries_count, payload_bytes)
  end
end

def scan_page_after(wal_paths : Array(String), after_lsn : UInt64, limit : Int32)
  count = 0
  bytes = 0
  next_lsn = after_lsn

  wal_paths.each do |wal_path|
    File.each_line(wal_path) do |line|
      next if line.blank?

      object = JSON.parse(line).as_h
      lsn = object["lsn"]?.try(&.as_i64?.try(&.to_u64))
      entry = object["entry"]?
      next if lsn.nil? || entry.nil?
      next unless lsn > after_lsn

      bytes += {lsn: lsn, entry: entry}.to_json.bytesize
      count += 1
      next_lsn = lsn
      break if count >= limit
    end
    break if count >= limit
  end

  {count: count, bytes: bytes, next_lsn: next_lsn}
end

def indexed_page_after(after_lsn : UInt64, limit : Int32, dump_dir : String)
  page = Karma::Wal.entries_page_after(after_lsn, limit, dump_dir)
  next_lsn = page.entries.empty? ? after_lsn : page.entries.last.lsn
  {count: page.entries.size, bytes: page.bytes, next_lsn: next_lsn}
end

rss_kb_start = current_rss_kb
generation_started = Time.monotonic
wal_bytes = write_benchmark_wal(dump_dir, entries_count, payload_bytes, segment_bytes)
generation_ms = (Time.monotonic - generation_started).total_milliseconds
rss_kb_after_generation = current_rss_kb
wal_paths = Karma::Wal.paths(dump_dir)
segments = Karma::Wal.segment_paths(dump_dir)
sidecar_indexes = segments.count { |segment_path| File.exists?(Karma::Wal.segment_index_path(segment_path)) }
sidecar_bytes = segments.sum(0_i64) do |segment_path|
  index_path = Karma::Wal.segment_index_path(segment_path)
  File.exists?(index_path) ? File.size(index_path).to_i64 : 0_i64
end
sidecar_records = segments.sum(0_i64) do |segment_path|
  index_path = Karma::Wal.segment_index_path(segment_path)
  next 0_i64 unless File.exists?(index_path)

  records = File.read_lines(index_path).size - 1
  records > 0 ? records.to_i64 : 0_i64
end
target_after_lsn = after_lsn_override.nil? ? Math.max(entries_count - limit, 0).to_u64 : after_lsn_override.not_nil!
tail_page_entries = Math.min(limit, Math.max(entries_count.to_i64 - target_after_lsn.to_i64, 0_i64)).to_i64
results = [] of NamedTuple(
  name: String,
  operations: Int32 | Int64 | UInt64,
  requests: Int32,
  duration_ms: Float64,
  per_second: Float64,
  latency_p50_ms: Float64,
  latency_p95_ms: Float64,
)

unless skip_linear
  results << benchmark("linear_tail_page", tail_rounds.to_i64 * tail_page_entries, tail_rounds) do |latencies|
    tail_rounds.times do
      started = Time.monotonic
      scan_page_after(wal_paths, target_after_lsn, limit)
      latencies << (Time.monotonic - started).total_milliseconds
    end
  end
end

Karma::Wal.reset!
results << benchmark("indexed_cold_tail_page", tail_page_entries, 1) do |latencies|
  started = Time.monotonic
  indexed_page_after(target_after_lsn, limit, dump_dir)
  latencies << (Time.monotonic - started).total_milliseconds
end

results << benchmark("indexed_hot_tail_page", tail_rounds.to_i64 * tail_page_entries, tail_rounds) do |latencies|
  tail_rounds.times do
    started = Time.monotonic
    indexed_page_after(target_after_lsn, limit, dump_dir)
    latencies << (Time.monotonic - started).total_milliseconds
  end
end

linear_pages = 0
linear_operations = 0_i64
unless skip_linear || skip_sequential
  results << benchmark("linear_sequential_catchup", entries_count, (entries_count + limit - 1) // limit) do |latencies|
    after_lsn = 0_u64
    while after_lsn < entries_count
      started = Time.monotonic
      page = scan_page_after(wal_paths, after_lsn, limit)
      latencies << (Time.monotonic - started).total_milliseconds
      break if page[:count] == 0

      linear_pages += 1
      linear_operations += page[:count]
      after_lsn = page[:next_lsn]
    end
  end
end

Karma::Wal.reset!
indexed_pages = 0
indexed_operations = 0_i64
unless skip_sequential
  results << benchmark("indexed_sequential_catchup", entries_count, (entries_count + limit - 1) // limit) do |latencies|
    after_lsn = 0_u64
    while after_lsn < entries_count
      started = Time.monotonic
      page = indexed_page_after(after_lsn, limit, dump_dir)
      latencies << (Time.monotonic - started).total_milliseconds
      break if page[:count] == 0

      indexed_pages += 1
      indexed_operations += page[:count]
      after_lsn = page[:next_lsn]
    end
  end
end

if compare_sidecar && segment_bytes > 0
  segments.each do |segment_path|
    index_path = Karma::Wal.segment_index_path(segment_path)
    File.delete(index_path) if File.exists?(index_path)
  end
  Karma::Wal.reset!
  results << benchmark("indexed_cold_tail_page_without_sidecar", tail_page_entries, 1) do |latencies|
    started = Time.monotonic
    indexed_page_after(target_after_lsn, limit, dump_dir)
    latencies << (Time.monotonic - started).total_milliseconds
  end
end

rss_kb_after_benchmarks = current_rss_kb
output = {
  entries:            entries_count,
  limit:              limit,
  tail_rounds:        tail_rounds,
  payload_bytes:      payload_bytes,
  segment_bytes:      segment_bytes,
  after_lsn:          target_after_lsn,
  skip_linear:        skip_linear,
  skip_sequential:    skip_sequential,
  wal_files:          wal_paths.size,
  segments:           segments.size,
  sidecar_indexes:    sidecar_indexes,
  sidecar_bytes:      sidecar_bytes,
  sidecar_records:    sidecar_records,
  wal_bytes:          wal_bytes,
  rss_kb_start:       rss_kb_start,
  rss_kb_generation:  rss_kb_after_generation,
  rss_kb_end:         rss_kb_after_benchmarks,
  generation_ms:      generation_ms,
  generation_per_sec: generation_ms > 0.0 ? entries_count / (generation_ms / 1000.0) : 0.0,
  dump_dir:           dump_dir,
  linear_pages:       linear_pages,
  linear_operations:  linear_operations,
  indexed_pages:      indexed_pages,
  indexed_operations: indexed_operations,
  results:            results,
}

if json_output
  puts output.to_json
else
  puts "Karma WAL page benchmark"
  puts "entries=#{entries_count} limit=#{limit} tail_rounds=#{tail_rounds} payload_bytes=#{payload_bytes} segment_bytes=#{segment_bytes} after_lsn=#{target_after_lsn} skip_linear=#{skip_linear} skip_sequential=#{skip_sequential} wal_files=#{wal_paths.size} segments=#{segments.size} sidecar_indexes=#{sidecar_indexes} sidecar_bytes=#{sidecar_bytes} sidecar_records=#{sidecar_records} wal_bytes=#{wal_bytes} rss_kb_start=#{rss_kb_start} rss_kb_generation=#{rss_kb_after_generation} rss_kb_end=#{rss_kb_after_benchmarks} generation_ms=#{generation_ms.round(2)} generation_per_sec=#{(generation_ms > 0.0 ? entries_count / (generation_ms / 1000.0) : 0.0).round(2)}"
  results.each do |item|
    puts "#{item[:name]}: operations=#{item[:operations]} requests=#{item[:requests]} duration_ms=#{item[:duration_ms].round(2)} per_second=#{item[:per_second].round(2)} p50_ms=#{item[:latency_p50_ms].round(4)} p95_ms=#{item[:latency_p95_ms].round(4)}"
  end
end

Karma::Wal.reset!
FileUtils.rm_rf(dump_dir) unless keep_data
