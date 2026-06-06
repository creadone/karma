require "json"
require "time"

module KarmaClient
  class Client
    INT64_MAX = Int64::MAX

    @configuration : Configuration
    @connection : Connection
    @mutex : Mutex

    def initialize(configuration : Configuration? = nil, **options)
      @configuration = build_configuration(configuration, options)
      @connection = Connection.new(
        host: @configuration.host,
        port: @configuration.port,
        connect_timeout: @configuration.connect_timeout,
        read_timeout: @configuration.read_timeout,
        write_timeout: @configuration.write_timeout,
        tcp_nodelay: @configuration.tcp_nodelay
      )
      @mutex = Mutex.new
    end

    def close : Nil
      @connection.close
    end

    def request(op : String, fields = Hash(String, JSON::Any).new) : Response
      payload = build_payload(op, fields)
      @mutex.synchronize do
        Response.parse(@connection.request(payload))
      end
    end

    def request(op : String, **fields) : Response
      request(op, fields_to_hash(fields))
    end

    def call(op : String, fields = Hash(String, JSON::Any).new) : JSON::Any
      response = request(op, fields)
      raise ServerError.from_response(response) if response.error?

      response.value
    end

    def call(op : String, **fields) : JSON::Any
      call(op, fields_to_hash(fields))
    end

    def ping : JSON::Any
      call("system.ping")
    end

    def health : JSON::Any
      call("system.health")
    end

    def stats : JSON::Any
      call("system.stats")
    end

    def metrics : JSON::Any
      call("system.metrics")
    end

    def create_limit(limit : String) : JSON::Any
      create_series(limit)
    end

    def list_limits : JSON::Any
      list_series
    end

    def drop_limit(limit : String) : JSON::Any
      drop_series(limit)
    end

    def record_usage(limit : String, subject_id, amount = 1, day = nil, idempotency_key : String? = nil, fingerprint : String? = nil) : JSON::Any
      increment(
        series: limit,
        key: subject_id,
        value: amount,
        bucket: day,
        idempotency_key: idempotency_key,
        fingerprint: fingerprint
      )
    end

    def record_usage(limit : String, *, subject_id, amount = 1, day = nil, idempotency_key : String? = nil, fingerprint : String? = nil) : JSON::Any
      record_usage(limit, subject_id, amount, day, idempotency_key, fingerprint)
    end

    def set_usage(limit : String, subject_id, amount, day, idempotency_key : String? = nil, fingerprint : String? = nil) : JSON::Any
      batch_set(
        series: limit,
        items: [{subject_id, day, amount}],
        idempotency_key: idempotency_key,
        fingerprint: fingerprint
      )
    end

    def set_usage(limit : String, *, subject_id, amount, day, idempotency_key : String? = nil, fingerprint : String? = nil) : JSON::Any
      set_usage(limit, subject_id, amount, day, idempotency_key, fingerprint)
    end

    def record_usage_batch(limit : String, items, idempotency_key : String? = nil, fingerprint : String? = nil) : JSON::Any
      batch_add(series: limit, items: items, idempotency_key: idempotency_key, fingerprint: fingerprint)
    end

    def usage(limit : String, subject_id, range = nil, from = nil, to = nil) : UInt64
      sum(series: limit, key: subject_id, range: range, from: from, to: to).as_i64.to_u64
    end

    def usage(limit : String, *, subject_id, range = nil, from = nil, to = nil) : UInt64
      usage(limit, subject_id, range, from, to)
    end

    def batch_usage(limit : String, subject_ids, range = nil, from = nil, to = nil) : Hash(UInt64, UInt64)
      result = {} of UInt64 => UInt64
      batch_sum(series: limit, keys: subject_ids, range: range, from: from, to: to).as_a.each do |item|
        result[item["key"].as_i64.to_u64] = item["value"].as_i64.to_u64
      end
      result
    end

    def create_series(series : String) : JSON::Any
      call("tree.create", series: normalize_series(series))
    end

    def drop_series(series : String) : JSON::Any
      call("tree.drop", series: normalize_series(series))
    end

    def list_series : JSON::Any
      call("tree.list")
    end

    def series_info(series : String) : JSON::Any
      call("tree.info", series: normalize_series(series))
    end

    def increment(*, series : String, key, value = 1, bucket = nil, idempotency_key : String? = nil, fingerprint : String? = nil) : JSON::Any
      call("counter.increment", fields({
        "series"          => normalize_series(series),
        "key"             => normalize_u64(key, "key"),
        "value"           => normalize_u64(value, "value"),
        "bucket"          => optional_bucket(bucket, "bucket"),
        "idempotency_key" => optional_string(idempotency_key, "idempotency_key"),
        "fingerprint"     => optional_string(fingerprint, "fingerprint"),
      }))
    end

    def decrement(*, series : String, key, value = 1, bucket = nil, idempotency_key : String? = nil, fingerprint : String? = nil) : JSON::Any
      call("counter.decrement", fields({
        "series"          => normalize_series(series),
        "key"             => normalize_u64(key, "key"),
        "value"           => normalize_u64(value, "value"),
        "bucket"          => optional_bucket(bucket, "bucket"),
        "idempotency_key" => optional_string(idempotency_key, "idempotency_key"),
        "fingerprint"     => optional_string(fingerprint, "fingerprint"),
      }))
    end

    def sum(*, series : String, key, range = nil, from = nil, to = nil) : JSON::Any
      call("counter.sum", fields({
        "series" => normalize_series(series),
        "key"    => normalize_u64(key, "key"),
        "range"  => range_payload(range, from, to),
      }))
    end

    def points(*, series : String, key, range = nil, from = nil, to = nil) : JSON::Any
      call("counter.series", fields({
        "series" => normalize_series(series),
        "key"    => normalize_u64(key, "key"),
        "range"  => range_payload(range, from, to, required: true),
      }))
    end

    def batch_sum(*, series : String, keys, range = nil, from = nil, to = nil) : JSON::Any
      call("counter.batch_sum", fields({
        "series" => normalize_series(series),
        "keys"   => normalize_keys(keys),
        "range"  => range_payload(range, from, to),
      }))
    end

    def multi_sum(*, items, range = nil, from = nil, to = nil) : JSON::Any
      call("counter.multi_sum", fields({
        "items" => normalize_multi_sum_items(items),
        "range" => range_payload(range, from, to),
      }))
    end

    def batch_add(*, series : String, items, idempotency_key : String? = nil, fingerprint : String? = nil) : JSON::Any
      call("series.batch_add", fields({
        "series"          => normalize_series(series),
        "items"           => normalize_items(items),
        "idempotency_key" => optional_string(idempotency_key, "idempotency_key"),
        "fingerprint"     => optional_string(fingerprint, "fingerprint"),
      }))
    end

    def batch_set(*, series : String, items, idempotency_key : String? = nil, fingerprint : String? = nil) : JSON::Any
      call("series.batch_set", fields({
        "series"          => normalize_series(series),
        "items"           => normalize_items(items),
        "idempotency_key" => optional_string(idempotency_key, "idempotency_key"),
        "fingerprint"     => optional_string(fingerprint, "fingerprint"),
      }))
    end

    def reset_counter(*, series : String, key, idempotency_key : String? = nil, fingerprint : String? = nil) : JSON::Any
      call("counter.reset", fields({
        "series"          => normalize_series(series),
        "key"             => normalize_u64(key, "key"),
        "idempotency_key" => optional_string(idempotency_key, "idempotency_key"),
        "fingerprint"     => optional_string(fingerprint, "fingerprint"),
      }))
    end

    def batch_reset(*, series : String, keys, idempotency_key : String? = nil, fingerprint : String? = nil) : JSON::Any
      call("counter.batch_reset", fields({
        "series"          => normalize_series(series),
        "keys"            => normalize_keys(keys),
        "idempotency_key" => optional_string(idempotency_key, "idempotency_key"),
        "fingerprint"     => optional_string(fingerprint, "fingerprint"),
      }))
    end

    def delete_range(*, series : String, key = nil, range = nil, from = nil, to = nil, idempotency_key : String? = nil, fingerprint : String? = nil) : JSON::Any
      operation = key.nil? ? "tree.delete_range" : "counter.delete_range"
      call(operation, fields({
        "series"          => normalize_series(series),
        "key"             => optional_u64(key, "key"),
        "range"           => range_payload(range, from, to, required: true),
        "idempotency_key" => optional_string(idempotency_key, "idempotency_key"),
        "fingerprint"     => optional_string(fingerprint, "fingerprint"),
      }))
    end

    def idempotency_prune(*, before, limit = nil) : JSON::Any
      call("idempotency.prune", fields({
        "before" => normalize_timestamp(before, "before"),
        "limit"  => optional_limit(limit),
      }))
    end

    private def build_configuration(configuration : Configuration?, options)
      config = configuration ? configuration.copy : KarmaClient.configuration.copy
      apply_options(config, options)
      config.validate!
      config
    end

    private def apply_options(config : Configuration, options : NamedTuple) : Nil
      options.each do |key, value|
        case key
        when :host
          config.host = value.to_s
        when :port
          config.port = value.to_i
        when :token
          config.token = value.nil? ? nil : value.to_s
        when :connect_timeout
          config.connect_timeout = span_value(value, "connect_timeout")
        when :read_timeout
          config.read_timeout = span_value(value, "read_timeout")
        when :write_timeout
          config.write_timeout = span_value(value, "write_timeout")
        when :pool_size
          config.pool_size = value.to_i
        when :pool_timeout
          config.pool_timeout = span_value(value, "pool_timeout")
        when :tcp_nodelay
          config.tcp_nodelay = value ? true : false
        else
          raise ConfigurationError.new("Unknown Karma client option #{key}")
        end
      end
    end

    private def span_value(value : Time::Span, field : String) : Time::Span
      value
    end

    private def span_value(value : Number, field : String) : Time::Span
      value.to_f.seconds
    end

    private def span_value(value, field : String) : Time::Span
      value.to_s.to_f.seconds
    rescue ArgumentError
      raise ConfigurationError.new("#{field} must be a number or Time::Span")
    end

    private def build_payload(op : String, fields : Hash(String, JSON::Any)) : Hash(String, JSON::Any)
      payload = {
        "v"  => JSON::Any.new(2_i64),
        "op" => JSON::Any.new(op),
      }
      if token = present_token
        payload["token"] = JSON::Any.new(token)
      end

      fields.each do |key, value|
        next if value.raw.nil?

        payload[key] = value
      end

      payload
    end

    private def present_token : String?
      token = @configuration.token
      return nil if token.nil? || token.empty?

      token
    end

    private def fields(**values) : Hash(String, JSON::Any)
      fields_to_hash(values)
    end

    private def fields(values : Hash) : Hash(String, JSON::Any)
      hash = Hash(String, JSON::Any).new
      values.each do |key, value|
        json = json_any(value)
        hash[key.to_s] = json unless json.raw.nil?
      end
      hash
    end

    private def fields_to_hash(values : NamedTuple) : Hash(String, JSON::Any)
      hash = Hash(String, JSON::Any).new
      values.each do |key, value|
        json = json_any(value)
        hash[key.to_s] = json unless json.raw.nil?
      end
      hash
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
      normalized = normalize_u64(value, "integer")
      JSON::Any.new(normalized)
    end

    private def json_any(value : Float) : JSON::Any
      JSON::Any.new(value.to_f64)
    end

    private def json_any(value : String) : JSON::Any
      JSON::Any.new(value)
    end

    private def json_any(value : Symbol) : JSON::Any
      JSON::Any.new(value.to_s)
    end

    private def json_any(value : Array) : JSON::Any
      JSON::Any.new(value.map { |item| json_any(item) })
    end

    private def json_any(value : Tuple) : JSON::Any
      JSON::Any.new(value.to_a.map { |item| json_any(item) })
    end

    private def json_any(value : Hash) : JSON::Any
      hash = Hash(String, JSON::Any).new
      value.each do |key, item|
        hash[key.to_s] = json_any(item)
      end
      JSON::Any.new(hash)
    end

    private def json_any(value : NamedTuple) : JSON::Any
      hash = Hash(String, JSON::Any).new
      value.each do |key, item|
        hash[key.to_s] = json_any(item)
      end
      JSON::Any.new(hash)
    end

    private def normalize_series(value) : String
      normalize_string(value, "series")
    end

    private def normalize_string(value, field : String) : String
      string = value.to_s
      raise InputError.new("#{field} is required") if string.empty?

      string
    end

    private def optional_string(value, field : String) : String?
      return nil if value.nil?

      normalize_string(value, field)
    end

    private def normalize_integer(value, field : String) : Int64
      value.to_i64
    rescue ArgumentError | OverflowError
      raise InputError.new("#{field} must be an integer")
    end

    private def normalize_u64(value, field : String) : Int64
      integer = normalize_integer(value, field)
      unless integer >= 0 && integer <= INT64_MAX
        raise InputError.new("#{field} must be between 0 and #{INT64_MAX}")
      end

      integer
    end

    private def optional_u64(value, field : String) : Int64?
      return nil if value.nil?

      normalize_u64(value, field)
    end

    private def normalize_limit(value) : Int64
      limit = normalize_integer(value, "limit")
      raise InputError.new("limit must be greater than 0") unless limit > 0

      limit
    end

    private def optional_limit(value) : Int64?
      return nil if value.nil?

      normalize_limit(value)
    end

    private def normalize_keys(keys) : Array(Int64)
      array = keys.to_a
      raise InputError.new("keys must not be empty") if array.empty?

      array.map { |key| normalize_u64(key, "keys[]") }
    rescue ex : Exception
      raise ex if ex.is_a?(InputError)
      raise InputError.new("keys must be an array")
    end

    private def normalize_bucket(value, field : String) : Int64
      case value
      when Time
        bucket_from_time(value, field)
      when String
        bucket_from_string(value, field)
      else
        normalize_u64(value, field)
      end
    end

    private def optional_bucket(value, field : String) : Int64?
      return nil if value.nil?

      normalize_bucket(value, field)
    end

    private def bucket_from_time(value : Time, field : String) : Int64
      value.to_utc.to_s("%Y%m%d").to_i64
    end

    private def bucket_from_string(value : String, field : String) : Int64
      compact =
        if value.matches?(/\A\d{8}\z/)
          value
        elsif value.matches?(/\A\d{4}-\d{2}-\d{2}\z/)
          value.delete("-")
        else
          raise InputError.new("#{field} must use YYYYMMDD or YYYY-MM-DD")
        end

      year = compact[0, 4].to_i
      month = compact[4, 2].to_i
      day = compact[6, 2].to_i
      Time.utc(year, month, day)
      compact.to_i64
    rescue ArgumentError
      raise InputError.new("#{field} must be a valid date")
    end

    private def range_payload(range, from, to, required : Bool = false) : Hash(String, JSON::Any)?
      if range
        raise InputError.new("range cannot be combined with from/to") if from || to
        raise InputError.new("exclusive ranges are not supported") if range.responds_to?(:exclusive?) && range.exclusive?

        from = range.begin
        to = range.end
      end

      if from.nil? && to.nil?
        raise InputError.new("range is required") if required

        return nil
      end

      raise InputError.new("both from and to are required") if from.nil? || to.nil?

      {
        "from" => JSON::Any.new(normalize_bucket(from, "range.from")),
        "to"   => JSON::Any.new(normalize_bucket(to, "range.to")),
      }
    end

    private def normalize_items(items) : Array(Array(Int64))
      array = items.to_a
      raise InputError.new("items must not be empty") if array.empty?

      array.map_with_index { |item, index| normalize_item(item, "items[#{index}]") }
    rescue ex : Exception
      raise ex if ex.is_a?(InputError)
      raise InputError.new("items must be an array")
    end

    private def normalize_item(item : Tuple, field : String) : Array(Int64)
      raise InputError.new("#{field} must be {key, bucket, value}") unless item.size == 3

      [
        normalize_u64(item[0], "#{field}[0]"),
        normalize_bucket(item[1], "#{field}[1]"),
        normalize_u64(item[2], "#{field}[2]"),
      ]
    end

    private def normalize_item(item : NamedTuple, field : String) : Array(Int64)
      [
        normalize_u64(named_fetch(item, :key, field), "#{field}.key"),
        normalize_bucket(named_fetch(item, :bucket, field), "#{field}.bucket"),
        normalize_u64(named_fetch(item, :value, field), "#{field}.value"),
      ]
    end

    private def normalize_item(item, field : String) : Array(Int64)
      normalize_item(item.to_a, field)
    rescue ex : Exception
      raise ex if ex.is_a?(InputError)
      raise InputError.new("#{field} must be {key, bucket, value}")
    end

    private def normalize_multi_sum_items(items) : Array(Hash(String, JSON::Any))
      array = items.to_a
      raise InputError.new("items must not be empty") if array.empty?

      array.map_with_index do |item, index|
        field = "items[#{index}]"
        {
          "series" => JSON::Any.new(normalize_series(named_fetch(item, :series, field))),
          "key"    => JSON::Any.new(normalize_u64(named_fetch(item, :key, field), "#{field}.key")),
        }
      end
    rescue ex : Exception
      raise ex if ex.is_a?(InputError)
      raise InputError.new("items must be an array")
    end

    private def named_fetch(item : NamedTuple, key : Symbol, field : String)
      item[key]? || raise InputError.new("#{field}.#{key} is required")
    end

    private def named_fetch(item, key : Symbol, field : String)
      item[key]? || item[key.to_s]? || raise InputError.new("#{field}.#{key} is required")
    rescue ex : Exception
      raise ex if ex.is_a?(InputError)
      raise InputError.new("#{field} must include #{key}")
    end

    private def normalize_timestamp(value : Time, field : String) : String
      value.to_utc.to_rfc3339
    end

    private def normalize_timestamp(value, field : String)
      case value
      when Int
        normalize_integer(value, field)
      else
        normalize_string(value, field)
      end
    end
  end
end
