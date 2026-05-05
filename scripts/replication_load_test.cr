require "file_utils"
require "json"
require "option_parser"
require "socket"

binary = "bin/karma"
host = "127.0.0.1"
master_port = 19_090
slave_port = 19_091
clients = 4
keys = 10_000
batch_size = 1_000
write_batches = 100
read_rounds = 100
replication_batch_size = 1_000
replication_poll_interval_ms = 10
bootstrap_timeout_seconds = 60
catchup_timeout_seconds = 30
series = "links"
bucket = 20260505_u64
wal_fsync = false
keep_data = false
json_output = false
base_dir = File.join(Dir.tempdir, "karma_replication_load_test_#{Process.pid}")

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
  parser.banner = "Usage: crystal run scripts/replication_load_test.cr -- [options]"

  parser.on("--binary=path", "Karma binary path (default: #{binary})") { |value| binary = value }
  parser.on("--host=host", "Host to bind/connect (default: #{host})") { |value| host = value }
  parser.on("--master-port=port", "Master port (default: #{master_port})") { |value| master_port = value.to_i }
  parser.on("--slave-port=port", "Slave port (default: #{slave_port})") { |value| slave_port = value.to_i }
  parser.on("--clients=count", "Concurrent writer and reader clients (default: #{clients})") { |value| clients = value.to_i }
  parser.on("--keys=count", "Number of distinct keys (default: #{keys})") { |value| keys = value.to_i }
  parser.on("--batch-size=count", "Items/keys per batch request (default: #{batch_size})") { |value| batch_size = value.to_i }
  parser.on("--write-batches=count", "series.batch_add requests sent to master (default: #{write_batches})") { |value| write_batches = value.to_i }
  parser.on("--read-rounds=count", "counter.batch_sum requests sent to slave (default: #{read_rounds})") { |value| read_rounds = value.to_i }
  parser.on("--replication-batch-size=count", "WAL entries per slave poll (default: #{replication_batch_size})") { |value| replication_batch_size = value.to_i }
  parser.on("--replication-poll-interval-ms=ms", "Slave polling interval (default: #{replication_poll_interval_ms})") { |value| replication_poll_interval_ms = value.to_i }
  parser.on("--bootstrap-timeout-seconds=seconds", "Seconds to wait for slave snapshot bootstrap (default: #{bootstrap_timeout_seconds})") { |value| bootstrap_timeout_seconds = value.to_i }
  parser.on("--catchup-timeout-seconds=seconds", "Seconds to wait for slave WAL catch-up (default: #{catchup_timeout_seconds})") { |value| catchup_timeout_seconds = value.to_i }
  parser.on("--series=name", "Series name (default: #{series})") { |value| series = value }
  parser.on("--bucket=yyyymmdd", "Bucket date (default: #{bucket})") { |value| bucket = value.to_u64 }
  parser.on("--wal-fsync=flag", "Fsync WAL writes (default: #{wal_fsync})") { |value| wal_fsync = bool_flag(value) }
  parser.on("--base-dir=path", "Base temp data directory (default: #{base_dir})") { |value| base_dir = value }
  parser.on("--keep-data", "Keep master/slave data directories after the run") { keep_data = true }
  parser.on("--json", "Print JSON output") { json_output = true }
  parser.on("-h", "--help", "Show this help") do
    puts parser
    exit
  end
end

raise "binary does not exist: #{binary}. Build it first with `shards build --release`." unless File.exists?(binary)
raise "clients must be greater than 0" unless clients > 0
raise "keys must be greater than 0" unless keys > 0
raise "batch-size must be greater than 0" unless batch_size > 0
raise "write-batches must be >= 0" unless write_batches >= 0
raise "read-rounds must be >= 0" unless read_rounds >= 0
raise "replication-batch-size must be greater than 0" unless replication_batch_size > 0
raise "replication-poll-interval-ms must be greater than 0" unless replication_poll_interval_ms > 0
raise "bootstrap-timeout-seconds must be greater than 0" unless bootstrap_timeout_seconds > 0
raise "catchup-timeout-seconds must be greater than 0" unless catchup_timeout_seconds > 0

master_dir = File.join(base_dir, "master")
slave_dir = File.join(base_dir, "slave")

def connect_with_retry(host : String, port : Int32, attempts = 200) : TCPSocket
  last_error = nil
  attempts.times do
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

def request_once!(host : String, port : Int32, payload) : JSON::Any
  socket = connect_with_retry(host, port)
  request!(socket, payload)
ensure
  socket.try(&.close)
end

def percentile(sorted : Array(Float64), percentile : Float64) : Float64
  return 0.0 if sorted.empty?

  index = ((sorted.size - 1) * percentile).round.to_i
  sorted[index]
end

def result(name : String, operations : Int32 | Int64 | UInt64, latencies : Array(Float64), duration_ms : Float64)
  sorted = latencies.sort
  operations_count = operations.to_f
  {
    name:           name,
    operations:     operations,
    requests:       latencies.size,
    duration_ms:    duration_ms,
    per_second:     duration_ms > 0.0 ? operations_count / (duration_ms / 1000.0) : 0.0,
    latency_p50_ms: percentile(sorted, 0.50),
    latency_p95_ms: percentile(sorted, 0.95),
  }
end

def start_karma(binary : String, args : Array(String)) : Process
  Process.new(binary, args, output: Process::Redirect::Close, error: Process::Redirect::Inherit)
end

def stop_karma(process : Process?) : Nil
  return unless process

  process.signal(Signal::INT)
  process.wait
rescue
end

def batch_items(batch_index : Int32, keys : Int32, batch_size : Int32, bucket : UInt64)
  offset = (batch_index * batch_size) % keys
  Array(Tuple(UInt64, UInt64, UInt64)).new(batch_size) do |index|
    key = ((offset + index) % keys + 1).to_u64
    {key, bucket, 1_u64}
  end
end

def batch_keys(round : Int32, keys : Int32, batch_size : Int32)
  offset = (round * batch_size) % keys
  Array(UInt64).new(batch_size) do |index|
    ((offset + index) % keys + 1).to_u64
  end
end

def wait_until_replayed(host : String, port : Int32, target_lsn : UInt64, timeout : Time::Span) : JSON::Any
  deadline = Time.monotonic + timeout
  last_status = nil
  last_error = nil
  loop do
    begin
      status = request_once!(host, port, {v: 2, op: "replication.status"})
      last_status = status
      replayed_lsn = status["replayed_lsn"].as_i64.to_u64
      return status if replayed_lsn >= target_lsn
    rescue ex
      last_error = ex
    end
    break if Time.monotonic >= deadline

    sleep 20.milliseconds
  end

  raise "Slave did not reach LSN #{target_lsn}; last status: #{last_status}; last error: #{last_error}"
end

def sum_values(response : JSON::Any) : UInt64
  response.as_a.sum(0_u64) { |item| item["value"].as_i64.to_u64 }
end

FileUtils.rm_rf(base_dir)
Dir.mkdir_p(master_dir)
Dir.mkdir_p(slave_dir)

master : Process? = nil
slave : Process? = nil

begin
  common_args = [
    "--bind=#{host}",
    "--restore=false",
    "--wal=true",
    "--wal-fsync=#{wal_fsync}",
    "--max-request-bytes=#{64 * 1024 * 1024}",
    "--max-response-bytes=#{64 * 1024 * 1024}",
    "--read-timeout=30",
    "--write-timeout=30",
    "--query-timeout-ms=0",
    "--shutdown-timeout=1",
    "--log=false",
  ]

  master = start_karma(binary, common_args + [
    "--role=master",
    "--port=#{master_port}",
    "--directory=#{master_dir}",
  ])
  connect_with_retry(host, master_port).close

  seed_started = Time.monotonic
  (0...((keys + batch_size - 1) // batch_size)).each do |batch_index|
    items = batch_items(batch_index, keys, Math.min(batch_size, keys - batch_index * batch_size), bucket)
    request_once!(host, master_port, {v: 2, op: "series.batch_add", series: series, items: items})
  end
  seed_ms = (Time.monotonic - seed_started).total_milliseconds

  request_once!(host, master_port, {v: 2, op: "snapshot.create_all"})
  master_snapshot_status = request_once!(host, master_port, {v: 2, op: "replication.status"})
  snapshot_lsn = master_snapshot_status["last_snapshot_lsn"].as_i64.to_u64

  slave = start_karma(binary, [
    "--bind=#{host}",
    "--role=slave",
    "--port=#{slave_port}",
    "--directory=#{slave_dir}",
    "--restore=true",
    "--wal=true",
    "--wal-fsync=#{wal_fsync}",
    "--max-request-bytes=#{64 * 1024 * 1024}",
    "--max-response-bytes=#{64 * 1024 * 1024}",
    "--read-timeout=30",
    "--write-timeout=30",
    "--query-timeout-ms=0",
    "--shutdown-timeout=1",
    "--replication-source-host=#{host}",
    "--replication-source-port=#{master_port}",
    "--replication-batch-size=#{replication_batch_size}",
    "--replication-poll-interval-ms=#{replication_poll_interval_ms}",
    "--log=false",
  ])

  bootstrap_started = Time.monotonic
  wait_until_replayed(host, slave_port, snapshot_lsn, bootstrap_timeout_seconds.seconds)
  bootstrap_ms = (Time.monotonic - bootstrap_started).total_milliseconds

  writer_channel = Channel(NamedTuple(latencies: Array(Float64), error: String?)).new
  reader_channel = Channel(NamedTuple(latencies: Array(Float64), error: String?)).new
  started = Time.monotonic

  clients.times do |client_index|
    spawn do
      latencies = [] of Float64
      socket = connect_with_retry(host, master_port)
      begin
        write_batches.times do |batch_index|
          next unless batch_index % clients == client_index

          started_request = Time.monotonic
          request!(socket, {v: 2, op: "series.batch_add", series: series, items: batch_items(batch_index, keys, batch_size, bucket)})
          latencies << (Time.monotonic - started_request).total_milliseconds
        end
        writer_channel.send({latencies: latencies, error: nil})
      rescue ex
        writer_channel.send({latencies: latencies, error: ex.message || ex.class.name})
      ensure
        socket.close unless socket.closed?
      end
    end

    spawn do
      latencies = [] of Float64
      socket = connect_with_retry(host, slave_port)
      begin
        read_rounds.times do |round|
          next unless round % clients == client_index

          started_request = Time.monotonic
          request!(socket, {v: 2, op: "counter.batch_sum", series: series, keys: batch_keys(round, keys, batch_size)})
          latencies << (Time.monotonic - started_request).total_milliseconds
        end
        reader_channel.send({latencies: latencies, error: nil})
      rescue ex
        reader_channel.send({latencies: latencies, error: ex.message || ex.class.name})
      ensure
        socket.close unless socket.closed?
      end
    end
  end

  writer_latencies = [] of Float64
  reader_latencies = [] of Float64
  errors = [] of String

  clients.times do
    result = writer_channel.receive
    writer_latencies.concat(result[:latencies])
    errors << result[:error].not_nil! unless result[:error].nil?
  end

  clients.times do
    result = reader_channel.receive
    reader_latencies.concat(result[:latencies])
    errors << result[:error].not_nil! unless result[:error].nil?
  end

  raise errors.join("; ") unless errors.empty?

  mixed_duration_ms = (Time.monotonic - started).total_milliseconds
  master_status = request_once!(host, master_port, {v: 2, op: "replication.status"})
  master_lsn = master_status["wal_current_lsn"].as_i64.to_u64
  slave_status = wait_until_replayed(host, slave_port, master_lsn, catchup_timeout_seconds.seconds)

  all_keys = (1_u64..keys.to_u64).to_a
  master_total = sum_values(request_once!(host, master_port, {v: 2, op: "counter.batch_sum", series: series, keys: all_keys}))
  slave_total = sum_values(request_once!(host, slave_port, {v: 2, op: "counter.batch_sum", series: series, keys: all_keys}))
  raise "Master/slave total mismatch: master=#{master_total} slave=#{slave_total}" unless master_total == slave_total

  writer_result = result("master_series.batch_add", write_batches.to_i64 * batch_size, writer_latencies, mixed_duration_ms)
  reader_result = result("slave_counter.batch_sum", read_rounds.to_i64 * batch_size, reader_latencies, mixed_duration_ms)
  final_lag = master_lsn - slave_status["replayed_lsn"].as_i64.to_u64

  output = {
    host:                         host,
    master_port:                  master_port,
    slave_port:                   slave_port,
    clients:                      clients,
    keys:                         keys,
    batch_size:                   batch_size,
    write_batches:                write_batches,
    read_rounds:                  read_rounds,
    replication_batch_size:       replication_batch_size,
    replication_poll_interval_ms: replication_poll_interval_ms,
    bootstrap_timeout_seconds:    bootstrap_timeout_seconds,
    catchup_timeout_seconds:      catchup_timeout_seconds,
    wal_fsync:                    wal_fsync,
    master_dir:                   master_dir,
    slave_dir:                    slave_dir,
    seed_ms:                      seed_ms,
    bootstrap_ms:                 bootstrap_ms,
    snapshot_lsn:                 snapshot_lsn,
    master_lsn:                   master_lsn,
    slave_replayed_lsn:           slave_status["replayed_lsn"].as_i64,
    final_lag_entries:            final_lag,
    master_total:                 master_total,
    slave_total:                  slave_total,
    slave_poll_attempts:          slave_status["replication_poll_attempt_count"].as_i64,
    slave_poll_errors:            slave_status["replication_poll_error_count"].as_i64,
    slave_bootstrap_attempts:     slave_status["replication_bootstrap_attempt_count"].as_i64,
    slave_bootstrap_errors:       slave_status["replication_bootstrap_error_count"].as_i64,
    results:                      [writer_result, reader_result],
  }

  if json_output
    puts output.to_json
  else
    puts "Karma replication load test"
    puts "master=#{host}:#{master_port} slave=#{host}:#{slave_port} clients=#{clients} keys=#{keys} batch_size=#{batch_size} write_batches=#{write_batches} read_rounds=#{read_rounds} wal_fsync=#{wal_fsync}"
    puts "snapshot_lsn=#{snapshot_lsn} master_lsn=#{master_lsn} slave_replayed_lsn=#{slave_status["replayed_lsn"].as_i64} final_lag_entries=#{final_lag} bootstrap_ms=#{bootstrap_ms.round(2)}"
    puts "master_total=#{master_total} slave_total=#{slave_total} slave_poll_attempts=#{slave_status["replication_poll_attempt_count"].as_i64} slave_poll_errors=#{slave_status["replication_poll_error_count"].as_i64}"
    [writer_result, reader_result].each do |entry|
      puts "#{entry[:name]}: operations=#{entry[:operations]} requests=#{entry[:requests]} duration_ms=#{entry[:duration_ms].round(2)} per_second=#{entry[:per_second].round(2)} p50_ms=#{entry[:latency_p50_ms].round(4)} p95_ms=#{entry[:latency_p95_ms].round(4)}"
    end
  end
ensure
  stop_karma(slave)
  stop_karma(master)
  FileUtils.rm_rf(base_dir) unless keep_data
end
