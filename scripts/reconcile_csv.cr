require "csv"
require "json"
require "option_parser"
require "socket"

host = "127.0.0.1"
port = 8080
series = "links"
csv_path = ""
key_column = "key"
bucket_column = "bucket"
value_column = "value"
batch_size = 1_000
sample_step = 1
max_mismatches = 20
json_output = false

OptionParser.parse do |parser|
  parser.banner = "Usage: crystal run scripts/reconcile_csv.cr -- --csv=expected.csv --series=links [options]"

  parser.on("--host=host", "Karma host (default: #{host})") { |value| host = value }
  parser.on("--port=port", "Karma port (default: #{port})") { |value| port = value.to_i }
  parser.on("--series=name", "Karma series/tree name (default: #{series})") { |value| series = value }
  parser.on("--csv=path", "CSV path with expected aggregates") { |value| csv_path = value }
  parser.on("--key-column=name", "CSV key column (default: #{key_column})") { |value| key_column = value }
  parser.on("--bucket-column=name", "CSV bucket column YYYYMMDD (default: #{bucket_column})") { |value| bucket_column = value }
  parser.on("--value-column=name", "CSV expected value column (default: #{value_column})") { |value| value_column = value }
  parser.on("--batch-size=count", "Keys per Karma batch_sum request (default: #{batch_size})") { |value| batch_size = value.to_i }
  parser.on("--sample-step=count", "Use every Nth CSV row (default: #{sample_step})") { |value| sample_step = value.to_i }
  parser.on("--max-mismatches=count", "Mismatch examples to print (default: #{max_mismatches})") { |value| max_mismatches = value.to_i }
  parser.on("--json", "Print JSON output") { json_output = true }
  parser.on("-h", "--help", "Show this help") do
    puts parser
    exit
  end
end

raise "--csv is required" if csv_path.empty?
raise "batch-size must be greater than 0" unless batch_size > 0
raise "sample-step must be greater than 0" unless sample_step > 0
raise "max-mismatches must be >= 0" unless max_mismatches >= 0

def checked_add(left : UInt64, right : UInt64) : UInt64
  raise "Expected value overflow" if UInt64::MAX - left < right

  left + right
end

expected = Hash(UInt64, Hash(UInt64, UInt64)).new do |hash, bucket|
  hash[bucket] = Hash(UInt64, UInt64).new(0_u64)
end

headers = [] of String
key_index = nil
bucket_index = nil
value_index = nil
rows_read = 0
rows_sampled = 0

File.open(csv_path) do |io|
  CSV.each_row(io) do |row|
    if headers.empty?
      headers = row.map(&.strip)
      key_index = headers.index(key_column)
      bucket_index = headers.index(bucket_column)
      value_index = headers.index(value_column)
      missing = [] of String
      missing << key_column if key_index.nil?
      missing << bucket_column if bucket_index.nil?
      missing << value_column if value_index.nil?
      raise "Missing CSV columns: #{missing.join(", ")}" unless missing.empty?
      next
    end

    rows_read += 1
    next unless ((rows_read - 1) % sample_step).zero?

    key = row[key_index.not_nil!].to_u64
    bucket = row[bucket_index.not_nil!].to_u64
    value = row[value_index.not_nil!].to_u64
    expected[bucket][key] = checked_add(expected[bucket][key], value)
    rows_sampled += 1
  end
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

mismatch_examples = [] of NamedTuple(bucket: UInt64, key: UInt64, expected: UInt64, actual: UInt64, delta: Int128)
checked_points = 0_i64
mismatch_count = 0_i64
absolute_drift = 0_u128

socket = TCPSocket.new(host, port)
begin
  expected.each do |bucket, values_by_key|
    values_by_key.keys.each_slice(batch_size) do |keys|
      response = request!(socket, {
        v:      2,
        op:     "counter.batch_sum",
        series: series,
        keys:   keys,
        range:  {from: bucket, to: bucket},
      })

      response.as_a.each do |item|
        key = item["key"].as_i64.to_u64
        actual = item["value"].as_i64.to_u64
        expected_value = values_by_key[key]
        checked_points += 1
        next if actual == expected_value

        mismatch_count += 1
        delta = actual.to_i128 - expected_value.to_i128
        absolute_drift += delta.abs.to_u128
        if mismatch_examples.size < max_mismatches
          mismatch_examples << {
            bucket:   bucket,
            key:      key,
            expected: expected_value,
            actual:   actual,
            delta:    delta,
          }
        end
      end
    end
  end
ensure
  socket.close unless socket.closed?
end

result = {
  host:              host,
  port:              port,
  series:            series,
  csv:               csv_path,
  rows_read:         rows_read,
  rows_sampled:      rows_sampled,
  checked_points:    checked_points,
  mismatch_count:    mismatch_count,
  absolute_drift:    absolute_drift,
  mismatch_examples: mismatch_examples,
  ok:                mismatch_count == 0,
}

if json_output
  puts result.to_json
else
  puts "Karma CSV reconciliation"
  puts "series=#{series} csv=#{csv_path} rows_read=#{rows_read} rows_sampled=#{rows_sampled} checked_points=#{checked_points}"
  puts "mismatch_count=#{mismatch_count} absolute_drift=#{absolute_drift}"
  mismatch_examples.each do |mismatch|
    puts "mismatch bucket=#{mismatch[:bucket]} key=#{mismatch[:key]} expected=#{mismatch[:expected]} actual=#{mismatch[:actual]} delta=#{mismatch[:delta]}"
  end
  puts(mismatch_count == 0 ? "status=ok" : "status=drift")
end

exit(mismatch_count == 0 ? 0 : 2)
