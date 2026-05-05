require "json"

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
      property checked_points : Int64?
      property mismatch_count : Int64?
      property absolute_drift : Int64?
      property max_abs_delta : Int64?
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
        @checked_points : Int64? = nil,
        @mismatch_count : Int64? = nil,
        @absolute_drift : Int64? = nil,
        @max_abs_delta : Int64? = nil,
        @protocol_version : UInt32 = 1_u32,
      )
      end

      def series : Karma::TimeSeries::Series
        Karma::TimeSeries::Series.new(tree_name.not_nil!)
      end

      def series_name : String
        tree_name.not_nil!
      end

      def series_key : Karma::TimeSeries::Key
        Karma::TimeSeries::Key.new(key.not_nil!)
      end

      def key_value : UInt64
        key.not_nil!
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

      def bucket_range? : Karma::TimeSeries::BucketRange?
        return nil if time_from.nil? && time_to.nil?

        bucket_range
      end

      def keyed? : Bool
        !key.nil?
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
  end
end
