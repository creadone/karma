require "json"

module Karma
  module Idempotency
    @@records = Hash(String, Record).new
    @@record_order = [] of String
    @@hits = 0_i64
    @@conflicts = 0_i64
    @@pruned = 0_i64
    @@write_count = 0_i64
    @@write_latency_ms_total = 0.0
    @@write_latency_ms_last = 0.0

    def self.eligible?(directive) : Bool
      return false unless directive.idempotency_key

      %w[
        increment
        decrement
        batch_add
        batch_set
        reset
        batch_reset
        delete
        batch_delete_range
      ].includes?(directive.command)
    end

    def self.execute(directive, use_persisted_timestamp : Bool = false, &)
      key = directive.idempotency_key.not_nil!
      validate_key!(key)
      created_at = created_at_unix(directive, use_persisted_timestamp)
      directive.idempotency_created_at_unix = created_at
      started_at = Time.monotonic
      request_fingerprint = fingerprint(directive)
      validate_external_fingerprint!(directive.fingerprint, request_fingerprint)

      if record = @@records[key]?
        if record.same_fingerprint?(request_fingerprint)
          record_hit
          return Result.new(record.response, true)
        end

        record_conflict
        raise Karma::Error.new("idempotency_conflict", "Idempotency key was already used with a different request")
      end

      response = yield
      response_json = json_response(response)
      store(Record.new(key, directive.command, request_fingerprint, response_json, created_at))
      record_write((Time.monotonic - started_at).total_milliseconds)
      Result.new(response_json, false)
    end

    def self.store(record : Record) : Nil
      unless @@records.has_key?(record.key)
        @@record_order << record.key
      end
      @@records[record.key] = record
      prune_expired
      enforce_max_records
    end

    def self.prune(before_unix : Int64, limit : Int32? = nil)
      raise Karma::Error.new("validation_error", "Field limit must be greater than 0") if limit && limit <= 0

      deleted = 0
      keys = @@record_order.select do |key|
        record = @@records[key]?
        record && record.created_at_unix < before_unix
      end

      keys.each do |key|
        break if limit && deleted >= limit

        if @@records.delete(key)
          deleted += 1
        end
      end

      compact_order
      @@pruned += deleted
      {deleted: deleted}
    end

    def self.records : Array(Record)
      @@record_order.compact_map { |key| @@records[key]? }
    end

    def self.replace_records(records : Array(Record)) : Nil
      @@records.clear
      @@record_order.clear
      records.sort_by(&.created_at_unix).each { |record| store(record) }
    end

    def self.metrics
      {
        record_count:           @@records.size,
        hits:                   @@hits,
        conflicts:              @@conflicts,
        pruned:                 @@pruned,
        write_count:            @@write_count,
        write_latency_ms_last:  @@write_latency_ms_last,
        write_latency_ms_avg:   @@write_count == 0 ? 0.0 : @@write_latency_ms_total / @@write_count,
        committed_stream_count: committed_stream_count,
      }
    end

    def self.reset! : Nil
      @@records.clear
      @@record_order.clear
      @@hits = 0_i64
      @@conflicts = 0_i64
      @@pruned = 0_i64
      @@write_count = 0_i64
      @@write_latency_ms_total = 0.0
      @@write_latency_ms_last = 0.0
      reset_committed_streams!
    end

    private def self.validate_key!(key : String) : Nil
      raise Karma::Error.new("validation_error", "Field idempotency_key must not be empty") if key.empty?
      raise Karma::Error.new("validation_error", "Field idempotency_key exceeds max size") if key.bytesize > 256
    end

    private def self.validate_external_fingerprint!(external : String?, computed : String) : Nil
      return if external.nil?
      raise Karma::Error.new("validation_error", "Field fingerprint must not be empty") if external.empty?
      raise Karma::Error.new("validation_error", "Field fingerprint exceeds max size") if external.bytesize > 512
      return if external == computed

      raise Karma::Error.new("idempotency_conflict", "Field fingerprint does not match request fingerprint")
    end

    private def self.created_at_unix(directive, use_persisted_timestamp : Bool) : Int64
      return Time.utc.to_unix unless use_persisted_timestamp

      directive.idempotency_created_at_unix || Time.utc.to_unix
    end

    private def self.json_response(response : JSON::Any) : JSON::Any
      response
    end

    private def self.json_response(response : Nil) : JSON::Any
      JSON::Any.new(nil)
    end

    private def self.json_response(response : Bool) : JSON::Any
      JSON::Any.new(response)
    end

    private def self.json_response(response : String) : JSON::Any
      JSON::Any.new(response)
    end

    private def self.json_response(response : Int32) : JSON::Any
      JSON::Any.new(response.to_i64)
    end

    private def self.json_response(response : Int64) : JSON::Any
      JSON::Any.new(response)
    end

    private def self.json_response(response : UInt64) : JSON::Any
      JSON::Any.new(response)
    end

    private def self.json_response(response : Float64) : JSON::Any
      JSON::Any.new(response)
    end

    private def self.json_response(response : NamedTuple) : JSON::Any
      fields = Hash(String, JSON::Any).new
      response.each do |key, value|
        fields[key.to_s] = json_response(value)
      end
      JSON::Any.new(fields)
    end

    private def self.json_response(response : Array) : JSON::Any
      JSON::Any.new(response.map { |value| json_response(value) })
    end

    private def self.json_response(response : Hash) : JSON::Any
      fields = Hash(String, JSON::Any).new
      response.each do |key, value|
        fields[key.to_s] = json_response(value)
      end
      JSON::Any.new(fields)
    end

    private def self.json_response(response) : JSON::Any
      JSON.parse(response.to_json)
    end

    private def self.record_hit : Nil
      @@hits += 1
    end

    private def self.record_conflict : Nil
      @@conflicts += 1
    end

    private def self.record_write(latency_ms : Float64) : Nil
      @@write_count += 1
      @@write_latency_ms_total += latency_ms
      @@write_latency_ms_last = latency_ms
    end

    private def self.prune_expired : Nil
      max_age = Karma.config.idempotency_max_age_seconds
      return if max_age <= 0

      before_unix = Time.utc.to_unix - max_age
      deleted = 0
      while key = @@record_order.first?
        record = @@records[key]?
        unless record
          @@record_order.shift
          next
        end
        break unless record.created_at_unix < before_unix

        @@records.delete(key)
        @@record_order.shift
        deleted += 1
      end
      return if deleted == 0

      @@pruned += deleted
    end

    private def self.enforce_max_records : Nil
      max_records = Karma.config.idempotency_max_records
      return if max_records <= 0

      deleted = 0
      while @@records.size > max_records
        key = @@record_order.shift?
        break unless key

        deleted += 1 if @@records.delete(key)
      end
      @@pruned += deleted
    end

    private def self.compact_order : Nil
      @@record_order = @@record_order.select { |key| @@records.has_key?(key) }
    end
  end
end
