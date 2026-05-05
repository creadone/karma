module Karma
  module Commands
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

    private def self.require_reconciliation_report(directive : Directive) : Nil
      checked_points = directive.checked_points
      mismatch_count = directive.mismatch_count
      raise Karma::Error.new("validation_error", "Field checked_points is required") if checked_points.nil?
      raise Karma::Error.new("validation_error", "Field mismatch_count is required") if mismatch_count.nil?
      raise Karma::Error.new("validation_error", "Field checked_points must be greater than or equal to 0") if checked_points < 0
      raise Karma::Error.new("validation_error", "Field mismatch_count must be greater than or equal to 0") if mismatch_count < 0
      raise Karma::Error.new("validation_error", "Field mismatch_count must be less than or equal to checked_points") if mismatch_count > checked_points
      raise Karma::Error.new("validation_error", "Field absolute_drift must be greater than or equal to 0") if (directive.absolute_drift || 0_i64) < 0
      raise Karma::Error.new("validation_error", "Field max_abs_delta must be greater than or equal to 0") if (directive.max_abs_delta || 0_i64) < 0
    end

    private def self.require_recovery_checkpoint(directive : Directive) : Nil
      source = directive.source
      raise Karma::Error.new("validation_error", "Field source is required") if source.nil? || source.empty?
      raise Karma::Error.new("validation_error", "Field offset or event_id is required") if directive.source_offset.nil? && directive.event_id.nil?
      raise Karma::Error.new("validation_error", "Field offset must not be empty") if directive.source_offset.try(&.empty?)
      raise Karma::Error.new("validation_error", "Field event_id must not be empty") if directive.event_id.try(&.empty?)
    end

    private def self.require_after_lsn(directive : Directive) : Nil
      raise Karma::Error.new("validation_error", "Field after_lsn is required") if directive.after_lsn.nil?
      require_limit(directive, default: 1_000, max: 10_000)
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
