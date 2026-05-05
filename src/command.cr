require "json"
require "./commands/*"

module Karma
  module Commands
    struct Directive
      include JSON::Serializable

      property command : String
      property tree_name : String?
      property key : UInt64?
      property keys : Array(UInt64)?
      property items : Array(Array(UInt64))?
      property time_from : UInt64?
      property time_to : UInt64?
      property date : UInt64?
      property value : UInt64?
      property token : String?
      property stream_id : String?
      property mode : String?
      property chunk_seq : UInt64?
      property granularity : String?
      property limit : Int32?
      property cursor : UInt64?
      property protocol_version : UInt32 = 1_u32

      def initialize(
        @command : String,
        @tree_name : String? = nil,
        @key : UInt64? = nil,
        @keys : Array(UInt64)? = nil,
        @items : Array(Array(UInt64))? = nil,
        @time_from : UInt64? = nil,
        @time_to : UInt64? = nil,
        @date : UInt64? = nil,
        @value : UInt64? = nil,
        @token : String? = nil,
        @stream_id : String? = nil,
        @mode : String? = nil,
        @chunk_seq : UInt64? = nil,
        @granularity : String? = nil,
        @limit : Int32? = nil,
        @cursor : UInt64? = nil,
        @protocol_version : UInt32 = 1_u32,
      )
      end

      def series : Karma::TimeSeries::Series
        Karma::TimeSeries::Series.new(tree_name.not_nil!)
      end

      def series_key : Karma::TimeSeries::Key
        Karma::TimeSeries::Key.new(key.not_nil!)
      end

      def bucket_from : Karma::TimeSeries::Bucket
        Karma::TimeSeries::Bucket.new(time_from.not_nil!)
      end

      def bucket_to : Karma::TimeSeries::Bucket
        Karma::TimeSeries::Bucket.new(time_to.not_nil!)
      end

      def bucket_range : Karma::TimeSeries::BucketRange
        Karma::TimeSeries::BucketRange.new(bucket_from, bucket_to)
      end

      def write_bucket : Karma::TimeSeries::Bucket
        if date = @date
          Karma::TimeSeries::Bucket.new(date)
        else
          Karma::TimeSeries::Bucket.today
        end
      end

      def write_value : UInt64
        @value || 1_u64
      end
    end

    COMMANDS = {
      "trees"         => Commands::Trees,
      "create"        => Commands::Create,
      "drop"          => Commands::Drop,
      "dump"          => Commands::Dump,
      "dump_all"      => Commands::DumpAll,
      "dumps"         => Commands::Dumps,
      "load"          => Commands::Load,
      "increment"     => Commands::Increment,
      "decrement"     => Commands::Decrement,
      "sum"           => Commands::Sum,
      "batch_sum"     => Commands::BatchSum,
      "batch_add"     => Commands::BatchAdd,
      "delete_before" => Commands::DeleteBefore,
      "compact"       => Commands::Compact,
      "find"          => Commands::Find,
      "reset"         => Commands::Reset,
      "delete"        => Commands::Delete,
      "health"        => Commands::Health,
      "stats"         => Commands::Stats,
      "metrics"       => Commands::Metrics,
      "verify"        => Commands::Verify,
      "ping"          => Commands::Ping,
      "tree_info"     => Commands::TreeInfo,
      "tree_keys"     => Commands::TreeKeys,
      "tree_summary"  => Commands::TreeSummary,
      "tree_top"      => Commands::TreeTop,
      "snapshot_info" => Commands::SnapshotInfo,
      "ingest_begin"  => Commands::IngestBegin,
      "ingest_chunk"  => Commands::IngestChunk,
      "ingest_commit" => Commands::IngestCommit,
      "ingest_abort"  => Commands::IngestAbort,
    }

    READ_ONLY_COMMANDS = %w[
      ping
      trees
      dumps
      health
      stats
      metrics
      verify
      sum
      batch_sum
      find
      tree_info
      tree_keys
      tree_summary
      tree_top
      snapshot_info
    ]

    def self.call(message, cluster, persist = true, authorize = true, synchronize = true, track_legacy = true, enforce_request_size = true)
      started_at = Time.monotonic
      protocol_version = request_protocol_version(message)
      if enforce_request_size && request_too_large?(message)
        Karma::Operations.record_command(false, elapsed_ms(started_at))
        return Karma::Protocol.error("request_too_large", "Request exceeds #{Karma.config.max_request_bytes} bytes", protocol_version)
      end

      begin
        directive = parse(message)
        protocol_version = directive.protocol_version
        if track_legacy && protocol_version == Karma::Protocol::VERSION
          Karma::Operations.record_legacy_request
          Karma::Log.info("protocol.v1_request", "command=#{directive.command}")
        end

        if COMMANDS.has_key?(directive.command)
          authenticate(directive) if authorize
          validate(directive)
          response = apply(directive, cluster, persist, synchronize)
          answer = Karma::Protocol.success(response, protocol_version)
          if response_too_large?(answer)
            Karma::Operations.record_command(false, elapsed_ms(started_at))
            return Karma::Protocol.error("response_too_large", "Response exceeds #{Karma.config.max_response_bytes} bytes", protocol_version)
          end

          Karma::Operations.record_command(true, elapsed_ms(started_at))
          return answer
        else
          raise Karma::Error.new("unknown_command", "Unknown command #{directive.command}")
        end
      rescue e : JSON::ParseException
        Karma::Operations.record_command(false, elapsed_ms(started_at))
        return Karma::Protocol.error("invalid_json", e.message || "Invalid JSON", protocol_version)
      rescue e : Karma::Error
        Karma::Operations.record_command(false, elapsed_ms(started_at))
        return Karma::Protocol.error(e.code, e.message || e.code, protocol_version)
      rescue e
        Karma::Operations.record_command(false, elapsed_ms(started_at))
        return Karma::Protocol.error("internal_error", e.message || e.class.name, protocol_version)
      end
    end

    def self.parse(message : String) : Directive
      payload = JSON.parse(message)
      object = payload.as_h

      if object.has_key?("op") || object["v"]?.try(&.as_i?) == 2
        parse_v2(object)
      else
        Directive.from_json(message)
      end
    rescue e : KeyError | TypeCastError
      raise Karma::Error.new("validation_error", e.message || "Invalid request")
    end

    private def self.request_protocol_version(message : String) : UInt32
      payload = JSON.parse(message)
      object = payload.as_h
      return 2_u32 if object.has_key?("op") || object["v"]?.try(&.as_i?) == 2

      Karma::Protocol::VERSION
    rescue
      Karma::Protocol::VERSION
    end

    private def self.elapsed_ms(started_at : Time::Span) : Float64
      (Time.monotonic - started_at).total_milliseconds
    end

    private def self.request_too_large?(message : String) : Bool
      max_request_bytes = Karma.config.max_request_bytes
      max_request_bytes > 0 && message.bytesize > max_request_bytes
    end

    private def self.response_too_large?(response : String) : Bool
      max_response_bytes = Karma.config.max_response_bytes
      max_response_bytes > 0 && response.bytesize > max_response_bytes
    end

    private def self.apply(directive : Directive, cluster, persist : Bool, synchronize : Bool)
      if synchronize
        Karma::State.synchronize { apply(directive, cluster, persist, synchronize: false) }
      else
        Karma::Wal.append(directive) if persist && Karma::Wal.persist?(directive)
        COMMANDS[directive.command].call(directive, cluster)
      end
    end

    private def self.authenticate(directive : Directive) : Nil
      write_token = Karma.config.auth_token
      read_token = Karma.config.read_auth_token
      return if write_token.nil? && read_token.nil?
      return if write_token && directive.token == write_token
      return if read_token && directive.token == read_token && read_only?(directive)

      if read_token && directive.token == read_token
        raise Karma::Error.new("forbidden", "Read-only token cannot execute command #{directive.command}")
      end

      raise Karma::Error.new("unauthorized", "Unauthorized")
    end

    private def self.read_only?(directive : Directive) : Bool
      READ_ONLY_COMMANDS.includes?(directive.command)
    end

    private def self.validate(directive : Directive) : Nil
      case directive.command
      when "ping", "trees", "dumps", "dump_all", "health", "stats", "metrics", "verify"
      when "snapshot_info"
      when "create", "drop", "dump", "load", "reset"
        require_tree_name(directive)
      when "tree_info"
        require_tree_name(directive)
      when "tree_keys"
        require_tree_name(directive)
        require_limit(directive, default: 100, max: 10_000)
      when "tree_summary"
        require_tree_name(directive)
        require_complete_range(directive) if directive.time_from || directive.time_to
      when "tree_top"
        require_tree_name(directive)
        require_limit(directive, default: 50, max: 1_000)
        require_complete_range(directive) if directive.time_from || directive.time_to
      when "increment", "decrement"
        require_tree_name(directive)
        require_key(directive)
        require_positive_value(directive) unless directive.value.nil?
      when "sum"
        require_tree_name(directive)
        require_key(directive)
        require_complete_range(directive) if directive.time_from || directive.time_to
      when "batch_sum"
        require_tree_name(directive)
        require_keys(directive)
        require_complete_range(directive) if directive.time_from || directive.time_to
      when "batch_add"
        require_tree_name(directive)
        require_items(directive)
      when "delete_before"
        require_tree_name(directive)
        require_date(directive)
      when "compact"
      when "ingest_begin"
        require_stream_id(directive)
        require_mode(directive)
      when "ingest_chunk"
        require_stream_id(directive)
        require_tree_name(directive)
        require_chunk_seq(directive)
        require_ingest_items(directive)
      when "ingest_commit", "ingest_abort"
        require_stream_id(directive)
        Karma::Ingest.validate_stream_exists!(directive.stream_id.not_nil!)
      when "find", "delete"
        require_tree_name(directive)
        require_complete_range(directive)
      else
        raise Karma::Error.new("unknown_command", "Unknown command #{directive.command}")
      end
    end

    private def self.parse_v2(object : Hash(String, JSON::Any)) : Directive
      op = object["op"]?.try(&.as_s?) || raise Karma::Error.new("validation_error", "Field op is required")
      token = object["token"]?.try(&.as_s?)

      case op
      when "system.ping"
        Directive.new("ping", token: token, protocol_version: 2_u32)
      when "system.health"
        Directive.new("health", token: token, protocol_version: 2_u32)
      when "system.stats"
        Directive.new("stats", token: token, protocol_version: 2_u32)
      when "system.metrics"
        Directive.new("metrics", token: token, protocol_version: 2_u32)
      when "snapshot.info"
        Directive.new("snapshot_info", token: token, protocol_version: 2_u32)
      when "tree.create"
        Directive.new("create", tree_name: tree_or_series(object), token: token, protocol_version: 2_u32)
      when "tree.drop"
        Directive.new("drop", tree_name: tree_or_series(object), token: token, protocol_version: 2_u32)
      when "tree.list"
        Directive.new("trees", token: token, protocol_version: 2_u32)
      when "tree.reset"
        Directive.new("reset", tree_name: tree_or_series(object), token: token, protocol_version: 2_u32)
      when "tree.info"
        Directive.new("tree_info", tree_name: tree_or_series(object), token: token, protocol_version: 2_u32)
      when "tree.keys"
        Directive.new("tree_keys", tree_name: tree_or_series(object), limit: limit_from(object), cursor: cursor_from(object), token: token, protocol_version: 2_u32)
      when "tree.summary"
        range = optional_range_from(object)
        Directive.new("tree_summary", tree_name: tree_or_series(object), time_from: range.try(&.from.value), time_to: range.try(&.to.value), token: token, protocol_version: 2_u32)
      when "tree.top"
        range = optional_range_from(object)
        Directive.new("tree_top", tree_name: tree_or_series(object), limit: limit_from(object), time_from: range.try(&.from.value), time_to: range.try(&.to.value), token: token, protocol_version: 2_u32)
      when "tree.series"
        range = range_from(object)
        Directive.new("find", tree_name: tree_or_series(object), time_from: range.from.value, time_to: range.to.value, token: token, protocol_version: 2_u32)
      when "tree.delete_range"
        range = range_from(object)
        Directive.new("delete", tree_name: tree_or_series(object), time_from: range.from.value, time_to: range.to.value, token: token, protocol_version: 2_u32)
      when "system.compact"
        Directive.new("compact", token: token, protocol_version: 2_u32)
      when "series.compact", "tree.compact"
        Directive.new("compact", tree_name: tree_or_series(object), token: token, protocol_version: 2_u32)
      when "counter.increment", "series.increment"
        Directive.new("increment", tree_name: tree_or_series(object), key: key_from(object), date: date_or_bucket(object), value: value_from(object), token: token, protocol_version: 2_u32)
      when "counter.batch_increment", "series.batch_add"
        Directive.new("batch_add", tree_name: tree_or_series(object), items: items_from(object), token: token, protocol_version: 2_u32)
      when "counter.decrement"
        Directive.new("decrement", tree_name: tree_or_series(object), key: key_from(object), date: date_or_bucket(object), value: value_from(object), token: token, protocol_version: 2_u32)
      when "counter.sum", "series.sum"
        range = optional_range_from(object)
        Directive.new("sum", tree_name: tree_or_series(object), key: key_from(object), time_from: range.try(&.from.value), time_to: range.try(&.to.value), token: token, protocol_version: 2_u32)
      when "counter.batch_sum", "series.batch_sum"
        range = optional_range_from(object)
        Directive.new("batch_sum", tree_name: tree_or_series(object), keys: keys_from(object), time_from: range.try(&.from.value), time_to: range.try(&.to.value), token: token, protocol_version: 2_u32)
      when "counter.series", "series.points"
        range = range_from(object)
        Directive.new("find", tree_name: tree_or_series(object), key: key_from(object), time_from: range.from.value, time_to: range.to.value, token: token, protocol_version: 2_u32)
      when "counter.delete_range"
        range = range_from(object)
        Directive.new("delete", tree_name: tree_or_series(object), key: key_from(object), time_from: range.from.value, time_to: range.to.value, token: token, protocol_version: 2_u32)
      when "series.delete_before", "tree.delete_before"
        Directive.new("delete_before", tree_name: tree_or_series(object), date: before_from(object), token: token, protocol_version: 2_u32)
      when "counter.reset"
        Directive.new("reset", tree_name: tree_or_series(object), key: key_from(object), token: token, protocol_version: 2_u32)
      when "snapshot.create"
        Directive.new("dump", tree_name: tree_or_series(object), token: token, protocol_version: 2_u32)
      when "snapshot.create_all"
        Directive.new("dump_all", token: token, protocol_version: 2_u32)
      when "snapshot.list"
        Directive.new("dumps", token: token, protocol_version: 2_u32)
      when "snapshot.load"
        file = object["file"]?.try(&.as_s?) || raise Karma::Error.new("validation_error", "Field file is required")
        Directive.new("load", tree_name: file, token: token, protocol_version: 2_u32)
      when "snapshot.verify"
        Directive.new("verify", token: token, protocol_version: 2_u32)
      when "ingest.begin"
        Directive.new("ingest_begin", stream_id: stream_id_from(object), mode: mode_from(object), granularity: granularity_from(object), token: token, protocol_version: 2_u32)
      when "ingest.chunk"
        Directive.new("ingest_chunk", tree_name: tree_or_series(object), stream_id: stream_id_from(object), chunk_seq: chunk_seq_from(object), items: items_from(object), token: token, protocol_version: 2_u32)
      when "ingest.commit"
        Directive.new("ingest_commit", stream_id: stream_id_from(object), token: token, protocol_version: 2_u32)
      when "ingest.abort"
        Directive.new("ingest_abort", stream_id: stream_id_from(object), token: token, protocol_version: 2_u32)
      else
        raise Karma::Error.new("unknown_command", "Unknown op #{op}")
      end
    end

    private def self.tree_or_series(object : Hash(String, JSON::Any)) : String
      object["tree"]?.try(&.as_s?) ||
        object["series"]?.try(&.as_s?) ||
        raise Karma::Error.new("validation_error", "Field tree or series is required")
    end

    private def self.key_from(object : Hash(String, JSON::Any)) : UInt64
      object["key"]?.try(&.as_i64.to_u64) ||
        raise Karma::Error.new("validation_error", "Field key is required")
    end

    private def self.keys_from(object : Hash(String, JSON::Any)) : Array(UInt64)
      object["keys"]?.try do |keys|
        keys.as_a.map(&.as_i64.to_u64)
      end || raise Karma::Error.new("validation_error", "Field keys is required")
    end

    private def self.items_from(object : Hash(String, JSON::Any)) : Array(Array(UInt64))
      object["items"]?.try do |items|
        items.as_a.map do |item|
          tuple = item.as_a
          raise Karma::Error.new("validation_error", "Each item must be [key, bucket, value]") unless tuple.size == 3

          tuple.map(&.as_i64.to_u64)
        end
      end || raise Karma::Error.new("validation_error", "Field items is required")
    end

    private def self.stream_id_from(object : Hash(String, JSON::Any)) : String
      object["stream_id"]?.try(&.as_s?) ||
        raise Karma::Error.new("validation_error", "Field stream_id is required")
    end

    private def self.mode_from(object : Hash(String, JSON::Any)) : String
      object["mode"]?.try(&.as_s?) ||
        raise Karma::Error.new("validation_error", "Field mode is required")
    end

    private def self.chunk_seq_from(object : Hash(String, JSON::Any)) : UInt64
      object["chunk_seq"]?.try(&.as_i64.to_u64) ||
        raise Karma::Error.new("validation_error", "Field chunk_seq is required")
    end

    private def self.granularity_from(object : Hash(String, JSON::Any)) : String?
      object["granularity"]?.try(&.as_s?)
    end

    private def self.limit_from(object : Hash(String, JSON::Any)) : Int32?
      object["limit"]?.try(&.as_i.to_i32)
    end

    private def self.cursor_from(object : Hash(String, JSON::Any)) : UInt64?
      object["cursor"]?.try do |cursor|
        cursor.raw.nil? ? nil : cursor.as_i64.to_u64
      end
    end

    private def self.date_or_bucket(object : Hash(String, JSON::Any)) : UInt64?
      object["date"]?.try(&.as_i64.to_u64) || object["bucket"]?.try do |bucket|
        if value = bucket.as_i64?
          value.to_u64
        else
          bucket.as_s.delete("-").to_u64
        end
      end
    end

    private def self.value_from(object : Hash(String, JSON::Any)) : UInt64?
      object["value"]?.try(&.as_i64.to_u64)
    end

    private def self.before_from(object : Hash(String, JSON::Any)) : UInt64
      object["before"]?.try(&.as_i64.to_u64) ||
        object["date"]?.try(&.as_i64.to_u64) ||
        raise Karma::Error.new("validation_error", "Field before is required")
    end

    private def self.optional_range_from(object : Hash(String, JSON::Any)) : Karma::TimeSeries::BucketRange?
      object.has_key?("range") ? range_from(object) : nil
    end

    private def self.range_from(object : Hash(String, JSON::Any)) : Karma::TimeSeries::BucketRange
      range = object["range"]?.try(&.as_h) || raise Karma::Error.new("validation_error", "Field range is required")
      from = range["from"]?.try(&.as_i64.to_u64) || raise Karma::Error.new("validation_error", "Field range.from is required")
      to = range["to"]?.try(&.as_i64.to_u64) || raise Karma::Error.new("validation_error", "Field range.to is required")
      Karma::TimeSeries::BucketRange.new(
        Karma::TimeSeries::Bucket.new(from),
        Karma::TimeSeries::Bucket.new(to)
      )
    end

    private def self.require_tree_name(directive : Directive) : Nil
      return unless directive.tree_name.nil? || directive.tree_name.to_s.empty?

      raise Karma::Error.new("validation_error", "Field tree_name is required")
    end

    private def self.require_key(directive : Directive) : Nil
      return unless directive.key.nil?

      raise Karma::Error.new("validation_error", "Field key is required")
    end

    private def self.require_keys(directive : Directive) : Nil
      keys = directive.keys
      raise Karma::Error.new("validation_error", "Field keys is required") if keys.nil?
      raise Karma::Error.new("validation_error", "Field keys exceeds max size") if keys.size > 10_000
    end

    private def self.require_limit(directive : Directive, default : Int32, max : Int32) : Nil
      directive.limit = default if directive.limit.nil?
      limit = directive.limit.not_nil!
      raise Karma::Error.new("validation_error", "Field limit must be greater than 0") if limit <= 0
      raise Karma::Error.new("validation_error", "Field limit exceeds max size") if limit > max
    end

    private def self.require_items(directive : Directive, allow_zero = false) : Nil
      items = directive.items
      raise Karma::Error.new("validation_error", "Field items is required") if items.nil?
      raise Karma::Error.new("validation_error", "Field items exceeds max size") if items.size > 10_000

      items.each do |item|
        raise Karma::Error.new("validation_error", "Each item must be [key, bucket, value]") unless item.size == 3
        raise Karma::Error.new("validation_error", "Batch item value must be greater than 0") if !allow_zero && item[2] == 0_u64
      end
    end

    private def self.require_stream_id(directive : Directive) : Nil
      return unless directive.stream_id.nil? || directive.stream_id.to_s.empty?

      raise Karma::Error.new("validation_error", "Field stream_id is required")
    end

    private def self.require_mode(directive : Directive) : Nil
      if directive.mode.nil? || directive.mode.to_s.empty?
        raise Karma::Error.new("validation_error", "Field mode is required")
      end

      mode = directive.mode.not_nil!
      unless Karma::Ingest::SUPPORTED_MODES.includes?(mode)
        raise Karma::Error.new("validation_error", "Unsupported ingest mode #{mode}")
      end
    end

    private def self.require_chunk_seq(directive : Directive) : Nil
      if directive.chunk_seq.nil?
        raise Karma::Error.new("validation_error", "Field chunk_seq is required")
      end

      begin
        stream = Karma::Ingest.validate_chunk!(directive.stream_id.not_nil!, directive.chunk_seq.not_nil!)
        Karma::Ingest.bind_series!(stream, directive.tree_name.not_nil!) if directive.tree_name
      rescue e : Karma::Error
        Karma::Ingest.record_rejected_chunk
        raise e
      end
    end

    private def self.require_ingest_items(directive : Directive) : Nil
      stream = Karma::Ingest.validate_stream_exists!(directive.stream_id.not_nil!)
      require_items(directive, allow_zero: stream.mode != "add")
    end

    private def self.require_positive_value(directive : Directive) : Nil
      return if directive.value.as(UInt64) > 0_u64

      raise Karma::Error.new("validation_error", "Field value must be greater than 0")
    end

    private def self.require_date(directive : Directive) : Nil
      return unless directive.date.nil?

      raise Karma::Error.new("validation_error", "Field date is required")
    end

    private def self.require_complete_range(directive : Directive) : Nil
      if directive.time_from.nil? || directive.time_to.nil?
        raise Karma::Error.new("validation_error", "Fields time_from and time_to are required together")
      end

      if directive.time_from.as(UInt64) > directive.time_to.as(UInt64)
        raise Karma::Error.new("validation_error", "Field time_from must be less than or equal to time_to")
      end

      require_max_range_days(directive.time_from.as(UInt64), directive.time_to.as(UInt64))
    end

    private def self.require_max_range_days(time_from : UInt64, time_to : UInt64) : Nil
      from = parse_bucket_date(time_from)
      to = parse_bucket_date(time_to)
      raise Karma::Error.new("validation_error", "Range exceeds max days") if (to - from).total_days > 366
    end

    private def self.parse_bucket_date(value : UInt64) : Time
      text = value.to_s
      raise Karma::Error.new("validation_error", "Invalid bucket date") unless text.size == 8

      year = text[0, 4].to_i
      month = text[4, 2].to_i
      day = text[6, 2].to_i
      Time.utc(year, month, day)
    rescue e : ArgumentError
      raise Karma::Error.new("validation_error", "Invalid bucket date")
    end
  end
end
