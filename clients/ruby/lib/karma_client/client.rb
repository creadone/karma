# frozen_string_literal: true

require "date"
require "time"

module KarmaClient
  class Client
    UINT64_MAX = (2**64) - 1

    def initialize(configuration = nil, **options)
      @configuration = build_configuration(configuration, options)
      @connection = Connection.new(**@configuration.to_connection_options)
      @mutex = Mutex.new
    end

    def close
      @connection.close
    end

    def request(op, **fields)
      payload = build_payload(op, fields)

      instrument(payload) do
        @mutex.synchronize do
          Response.parse(@connection.request(payload))
        end
      end
    end

    def call(op, **fields)
      response = request(op, **fields)
      raise ServerError.from_response(response) if response.error?

      response.value
    end

    def ping
      call("system.ping")
    end

    def health
      call("system.health")
    end

    def stats
      call("system.stats")
    end

    def metrics
      call("system.metrics")
    end

    def create_series(series)
      call("tree.create", series: normalize_series(series))
    end

    def drop_series(series)
      call("tree.drop", series: normalize_series(series))
    end

    def list_series
      call("tree.list")
    end

    def reset_series(series, idempotency_key: nil, fingerprint: nil)
      call("tree.reset", series: normalize_series(series), **idempotency_fields(idempotency_key, fingerprint))
    end

    def series_info(series)
      call("tree.info", series: normalize_series(series))
    end

    def series_keys(series, limit:, cursor: nil)
      call("tree.keys", series: normalize_series(series), limit: normalize_limit(limit), cursor: optional_u64(cursor, "cursor"))
    end

    def series_summary(series, range: nil, from: nil, to: nil)
      call("tree.summary", series: normalize_series(series), range: range_payload(range: range, from: from, to: to))
    end

    def series_top(series, limit:, range: nil, from: nil, to: nil)
      call(
        "tree.top",
        series: normalize_series(series),
        limit: normalize_limit(limit),
        range: range_payload(range: range, from: from, to: to)
      )
    end

    def compact_series(series)
      call("series.compact", series: normalize_series(series))
    end

    def compact_all
      call("system.compact")
    end

    def delete_before(series, before:)
      call("series.delete_before", series: normalize_series(series), before: normalize_bucket(before, "before"))
    end

    def increment(series:, key:, value: 1, bucket: nil, idempotency_key: nil, fingerprint: nil)
      call(
        "counter.increment",
        series: normalize_series(series),
        key: normalize_u64(key, "key"),
        value: normalize_u64(value, "value"),
        bucket: optional_bucket(bucket, "bucket"),
        **idempotency_fields(idempotency_key, fingerprint)
      )
    end

    def decrement(series:, key:, value: 1, bucket: nil, idempotency_key: nil, fingerprint: nil)
      call(
        "counter.decrement",
        series: normalize_series(series),
        key: normalize_u64(key, "key"),
        value: normalize_u64(value, "value"),
        bucket: optional_bucket(bucket, "bucket"),
        **idempotency_fields(idempotency_key, fingerprint)
      )
    end

    def sum(series:, key:, range: nil, from: nil, to: nil)
      call(
        "counter.sum",
        series: normalize_series(series),
        key: normalize_u64(key, "key"),
        range: range_payload(range: range, from: from, to: to)
      )
    end

    def points(series:, key:, range: nil, from: nil, to: nil)
      call(
        "counter.series",
        series: normalize_series(series),
        key: normalize_u64(key, "key"),
        range: range_payload(range: range, from: from, to: to, required: true)
      )
    end

    def series_points(series, range: nil, from: nil, to: nil)
      call(
        "tree.series",
        series: normalize_series(series),
        range: range_payload(range: range, from: from, to: to, required: true)
      )
    end

    def batch_sum(series:, keys:, range: nil, from: nil, to: nil)
      call(
        "counter.batch_sum",
        series: normalize_series(series),
        keys: normalize_keys(keys),
        range: range_payload(range: range, from: from, to: to)
      )
    end

    def multi_sum(items:, range: nil, from: nil, to: nil)
      call(
        "counter.multi_sum",
        items: normalize_multi_sum_items(items),
        range: range_payload(range: range, from: from, to: to)
      )
    end

    def batch_add(series:, items:, idempotency_key: nil, fingerprint: nil)
      call(
        "series.batch_add",
        series: normalize_series(series),
        items: normalize_items(items),
        **idempotency_fields(idempotency_key, fingerprint)
      )
    end

    def batch_set(series:, items:, idempotency_key: nil, fingerprint: nil)
      call(
        "series.batch_set",
        series: normalize_series(series),
        items: normalize_items(items),
        **idempotency_fields(idempotency_key, fingerprint)
      )
    end

    def reset_counter(series:, key:, idempotency_key: nil, fingerprint: nil)
      call(
        "counter.reset",
        series: normalize_series(series),
        key: normalize_u64(key, "key"),
        **idempotency_fields(idempotency_key, fingerprint)
      )
    end

    def batch_reset(series:, keys:, idempotency_key: nil, fingerprint: nil)
      call(
        "counter.batch_reset",
        series: normalize_series(series),
        keys: normalize_keys(keys),
        **idempotency_fields(idempotency_key, fingerprint)
      )
    end

    def delete_range(series:, key: nil, range: nil, from: nil, to: nil, idempotency_key: nil, fingerprint: nil)
      operation = key.nil? ? "tree.delete_range" : "counter.delete_range"
      call(
        operation,
        series: normalize_series(series),
        key: optional_u64(key, "key"),
        range: range_payload(range: range, from: from, to: to, required: true),
        **idempotency_fields(idempotency_key, fingerprint)
      )
    end

    def batch_delete_range(series:, keys:, range: nil, from: nil, to: nil, idempotency_key: nil, fingerprint: nil)
      call(
        "counter.batch_delete_range",
        series: normalize_series(series),
        keys: normalize_keys(keys),
        range: range_payload(range: range, from: from, to: to, required: true),
        **idempotency_fields(idempotency_key, fingerprint)
      )
    end

    def ingest_begin(stream_id:, mode:, granularity: "day")
      call("ingest.begin", stream_id: normalize_string(stream_id, "stream_id"), mode: normalize_string(mode, "mode"), granularity: granularity)
    end

    def ingest_chunk(stream_id:, series:, chunk_seq:, items:)
      call(
        "ingest.chunk",
        stream_id: normalize_string(stream_id, "stream_id"),
        series: normalize_series(series),
        chunk_seq: normalize_u64(chunk_seq, "chunk_seq"),
        items: normalize_items(items)
      )
    end

    def ingest_commit(stream_id:)
      call("ingest.commit", stream_id: normalize_string(stream_id, "stream_id"))
    end

    def ingest_abort(stream_id:)
      call("ingest.abort", stream_id: normalize_string(stream_id, "stream_id"))
    end

    def snapshot_create(series)
      call("snapshot.create", series: normalize_series(series))
    end

    def snapshot_create_all
      call("snapshot.create_all")
    end

    def snapshot_list
      call("snapshot.list")
    end

    def snapshot_info
      call("snapshot.info")
    end

    def snapshot_load(file)
      call("snapshot.load", file: normalize_snapshot_file(file))
    end

    def snapshot_fetch(file)
      call("snapshot.fetch", file: normalize_snapshot_file(file))
    end

    def snapshot_fetch_chunk(file, offset:, limit:)
      call(
        "snapshot.fetch_chunk",
        file: normalize_snapshot_file(file),
        offset: normalize_u64(offset, "offset"),
        limit: normalize_limit(limit)
      )
    end

    def snapshot_verify
      call("snapshot.verify")
    end

    def recovery_checkpoint(source:, offset:, event_id: nil)
      call(
        "recovery.checkpoint",
        source: normalize_string(source, "source"),
        offset: normalize_string(offset, "offset"),
        event_id: optional_string(event_id, "event_id")
      )
    end

    def recovery_status(source: nil)
      call("recovery.status", source: optional_string(source, "source"))
    end

    def reconciliation_report(checked_points:, mismatch_count:, absolute_drift: 0, max_abs_delta: 0)
      call(
        "reconciliation.report",
        checked_points: normalize_integer(checked_points, "checked_points"),
        mismatch_count: normalize_integer(mismatch_count, "mismatch_count"),
        absolute_drift: normalize_integer(absolute_drift, "absolute_drift"),
        max_abs_delta: normalize_integer(max_abs_delta, "max_abs_delta")
      )
    end

    def replication_status
      call("replication.status")
    end

    def replication_entries(after_lsn:, limit: nil)
      call("replication.entries", after_lsn: normalize_u64(after_lsn, "after_lsn"), limit: optional_limit(limit))
    end

    def idempotency_prune(before:, limit: nil)
      call("idempotency.prune", before: normalize_timestamp(before, "before"), limit: optional_limit(limit))
    end

    private

    def build_configuration(configuration, options)
      config = case configuration
               when nil
                 KarmaClient.configuration.dup
               when Configuration
                 configuration.dup
               when Hash
                 KarmaClient.configuration.dup.tap { |copy| apply_options(copy, configuration) }
               else
                 raise ConfigurationError, "Expected KarmaClient::Configuration or Hash"
               end
      apply_options(config, options)
      config
    end

    def apply_options(config, options)
      options.each do |key, value|
        setter = "#{key}="
        unless config.respond_to?(setter)
          raise ConfigurationError, "Unknown Karma client option #{key}"
        end

        config.public_send(setter, value)
      end
    end

    def build_payload(op, fields)
      payload = { "v" => 2, "op" => op.to_s }
      payload["token"] = @configuration.token if Configuration.present?(@configuration.token)

      fields.each do |key, value|
        next if value.nil?

        payload[key.to_s] = value
      end

      payload
    end

    def idempotency_fields(idempotency_key, fingerprint)
      {
        idempotency_key: optional_string(idempotency_key, "idempotency_key"),
        fingerprint: optional_string(fingerprint, "fingerprint")
      }
    end

    def instrument(payload)
      instrumenter = @configuration.instrumenter
      instrumenter ||= ActiveSupport::Notifications if defined?(ActiveSupport::Notifications)

      return yield unless instrumenter&.respond_to?(:instrument)

      instrumenter.instrument("request.karma_client", operation: payload["op"], series: payload["series"]) do
        yield
      end
    end

    def normalize_series(value)
      normalize_string(value, "series")
    end

    def normalize_string(value, field)
      string = value.to_s
      raise InputError, "#{field} is required" if string.empty?

      string
    end

    def optional_string(value, field)
      return nil if value.nil?

      normalize_string(value, field)
    end

    def normalize_integer(value, field)
      case value
      when Integer
        value
      when String
        Integer(value, 10)
      else
        if value.respond_to?(:to_int)
          value.to_int
        else
          raise ArgumentError
        end
      end
    rescue ArgumentError, TypeError
      raise InputError, "#{field} must be an integer"
    end

    def normalize_u64(value, field)
      integer = normalize_integer(value, field)
      unless integer.between?(0, UINT64_MAX)
        raise InputError, "#{field} must be between 0 and #{UINT64_MAX}"
      end

      integer
    end

    def optional_u64(value, field)
      return nil if value.nil?

      normalize_u64(value, field)
    end

    def normalize_limit(value)
      limit = normalize_integer(value, "limit")
      raise InputError, "limit must be greater than 0" unless limit.positive?

      limit
    end

    def optional_limit(value)
      return nil if value.nil?

      normalize_limit(value)
    end

    def normalize_keys(keys)
      array = Array(keys)
      raise InputError, "keys must not be empty" if array.empty?

      array.map { |key| normalize_u64(key, "keys[]") }
    rescue TypeError
      raise InputError, "keys must be an array"
    end

    def normalize_bucket(value, field)
      case value
      when Integer
        normalize_u64(value, field)
      when Date
        value.strftime("%Y%m%d").to_i
      when Time
        value.utc.strftime("%Y%m%d").to_i
      when String
        normalize_bucket_string(value, field)
      else
        raise InputError, "#{field} must be an Integer, Date, Time, or String"
      end
    end

    def optional_bucket(value, field)
      return nil if value.nil?

      normalize_bucket(value, field)
    end

    def normalize_bucket_string(value, field)
      compact = if value.match?(/\A\d{8}\z/)
                  value
                elsif value.match?(/\A\d{4}-\d{2}-\d{2}\z/)
                  Date.iso8601(value).strftime("%Y%m%d")
                else
                  raise InputError, "#{field} must use YYYYMMDD or YYYY-MM-DD"
                end

      normalize_u64(compact, field)
    rescue Date::Error
      raise InputError, "#{field} must be a valid date"
    end

    def range_payload(range: nil, from: nil, to: nil, required: false)
      if range
        raise InputError, "range cannot be combined with from/to" if from || to
        raise InputError, "exclusive ranges are not supported" if range.respond_to?(:exclude_end?) && range.exclude_end?

        from = range.begin
        to = range.end
      end

      if from.nil? && to.nil?
        raise InputError, "range is required" if required

        return nil
      end

      raise InputError, "both from and to are required" if from.nil? || to.nil?

      { from: normalize_bucket(from, "range.from"), to: normalize_bucket(to, "range.to") }
    end

    def normalize_items(items)
      array = Array(items)
      raise InputError, "items must not be empty" if array.empty?

      array.map.with_index do |item, index|
        normalize_item(item, "items[#{index}]")
      end
    rescue TypeError
      raise InputError, "items must be an array"
    end

    def normalize_item(item, field)
      if item.is_a?(Hash)
        [
          normalize_u64(hash_fetch(item, :key, field), "#{field}.key"),
          normalize_bucket(hash_fetch(item, :bucket, field), "#{field}.bucket"),
          normalize_u64(hash_fetch(item, :value, field), "#{field}.value")
        ]
      else
        tuple = Array(item)
        raise InputError, "#{field} must be [key, bucket, value]" unless tuple.size == 3

        [
          normalize_u64(tuple[0], "#{field}[0]"),
          normalize_bucket(tuple[1], "#{field}[1]"),
          normalize_u64(tuple[2], "#{field}[2]")
        ]
      end
    rescue TypeError
      raise InputError, "#{field} must be [key, bucket, value]"
    end

    def normalize_multi_sum_items(items)
      array = Array(items)
      raise InputError, "items must not be empty" if array.empty?

      array.map.with_index do |item, index|
        field = "items[#{index}]"
        unless item.is_a?(Hash)
          raise InputError, "#{field} must be a Hash with series and key"
        end

        {
          series: normalize_series(hash_fetch(item, :series, field)),
          key: normalize_u64(hash_fetch(item, :key, field), "#{field}.key")
        }
      end
    rescue TypeError
      raise InputError, "items must be an array"
    end

    def hash_fetch(hash, key, field)
      return hash[key] if hash.key?(key)
      return hash[key.to_s] if hash.key?(key.to_s)

      raise InputError, "#{field}.#{key} is required"
    end

    def normalize_snapshot_file(file)
      value = normalize_string(file, "file")
      raise InputError, "file must be a basename" unless File.basename(value) == value
      raise InputError, "file must end with .tree" unless value.end_with?(".tree")

      value
    end

    def normalize_timestamp(value, field)
      case value
      when Integer
        normalize_integer(value, field)
      when Time
        value.utc.iso8601
      when Date
        Time.utc(value.year, value.month, value.day).iso8601
      else
        normalize_string(value, field)
      end
    end
  end
end
