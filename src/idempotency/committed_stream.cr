require "json"

module Karma
  module Idempotency
    struct CommittedStream
      include JSON::Serializable

      getter stream_id : String
      getter mode : String
      getter granularity : String?
      getter series_name : String?
      getter last_chunk_seq : UInt64
      getter begin_fingerprint : String
      getter chunk_fingerprints : Hash(UInt64, String)
      getter committed_at_unix : Int64

      def initialize(
        @stream_id : String,
        @mode : String,
        @granularity : String?,
        @series_name : String?,
        @last_chunk_seq : UInt64,
        @begin_fingerprint : String,
        @chunk_fingerprints : Hash(UInt64, String),
        @committed_at_unix : Int64,
      )
      end

      def compatible_begin?(mode : String, granularity : String?) : Bool
        @mode == mode && @granularity == granularity
      end

      def compatible_chunk?(chunk_seq : UInt64, fingerprint : String, series_name : String) : Bool
        return false if chunk_seq > @last_chunk_seq
        return false if @series_name && @series_name != series_name

        @chunk_fingerprints[chunk_seq]? == fingerprint
      end

      def to_status(status : String)
        {
          stream_id:      stream_id,
          mode:           mode,
          series:         series_name,
          granularity:    granularity,
          status:         status,
          last_chunk_seq: last_chunk_seq,
        }
      end
    end
  end
end
