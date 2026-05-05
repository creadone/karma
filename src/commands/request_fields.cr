require "json"

module Karma
  module Commands
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

    private def self.snapshot_file_from(object : Hash(String, JSON::Any)) : String
      file = object["file"]?.try(&.as_s?) ||
             raise Karma::Error.new("validation_error", "Field file is required")
      raise Karma::Error.new("validation_error", "Field file must not be empty") if file.empty?
      raise Karma::Error.new("validation_error", "Field file must be a snapshot basename") unless File.basename(file) == file
      raise Karma::Error.new("validation_error", "Field file must end with .tree") unless file.ends_with?(Karma::Backup::DUMP_EXTENSION)

      file
    end

    private def self.mode_from(object : Hash(String, JSON::Any)) : String
      object["mode"]?.try(&.as_s?) ||
        raise Karma::Error.new("validation_error", "Field mode is required")
    end

    private def self.chunk_seq_from(object : Hash(String, JSON::Any)) : UInt64
      object["chunk_seq"]?.try(&.as_i64.to_u64) ||
        raise Karma::Error.new("validation_error", "Field chunk_seq is required")
    end

    private def self.checked_points_from(object : Hash(String, JSON::Any)) : Int64
      object["checked_points"]?.try(&.as_i64) ||
        raise Karma::Error.new("validation_error", "Field checked_points is required")
    end

    private def self.mismatch_count_from(object : Hash(String, JSON::Any)) : Int64
      object["mismatch_count"]?.try(&.as_i64) ||
        raise Karma::Error.new("validation_error", "Field mismatch_count is required")
    end

    private def self.absolute_drift_from(object : Hash(String, JSON::Any)) : Int64
      object["absolute_drift"]?.try(&.as_i64) || 0_i64
    end

    private def self.max_abs_delta_from(object : Hash(String, JSON::Any)) : Int64
      object["max_abs_delta"]?.try(&.as_i64) || 0_i64
    end

    private def self.source_from(object : Hash(String, JSON::Any)) : String
      object["source"]?.try(&.as_s?) ||
        raise Karma::Error.new("validation_error", "Field source is required")
    end

    private def self.optional_source_from(object : Hash(String, JSON::Any)) : String?
      object["source"]?.try(&.as_s?)
    end

    private def self.source_offset_from(object : Hash(String, JSON::Any)) : String?
      stringish_from(object, "source_offset") || stringish_from(object, "offset")
    end

    private def self.event_id_from(object : Hash(String, JSON::Any)) : String?
      stringish_from(object, "event_id")
    end

    private def self.stringish_from(object : Hash(String, JSON::Any), field : String) : String?
      return nil unless value = object[field]?

      value.as_s? || value.as_i64?.try(&.to_s) ||
        raise Karma::Error.new("validation_error", "Field #{field} must be a string or integer")
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

    private def self.offset_from(object : Hash(String, JSON::Any)) : UInt64?
      object["offset"]?.try do |offset|
        value = offset.as_i64
        raise Karma::Error.new("validation_error", "Field offset must be greater than or equal to 0") if value < 0

        value.to_u64
      end
    end

    private def self.after_lsn_from(object : Hash(String, JSON::Any)) : UInt64
      value = object["after_lsn"]?.try(&.as_i64) ||
              raise Karma::Error.new("validation_error", "Field after_lsn is required")
      raise Karma::Error.new("validation_error", "Field after_lsn must be greater than or equal to 0") if value < 0

      value.to_u64
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
  end
end
