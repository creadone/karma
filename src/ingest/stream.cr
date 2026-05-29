module Karma
  module Ingest
    class Stream
      getter stream_id : String
      getter mode : String
      getter granularity : String?
      property last_chunk_seq : UInt64
      property series_name : String?
      property staged_tree : CounterTree::Tree?
      property begin_fingerprint : String
      getter chunk_fingerprints : Hash(UInt64, String)

      def initialize(@stream_id : String, @mode : String, @granularity : String?, @begin_fingerprint : String)
        @last_chunk_seq = 0_u64
        @chunk_fingerprints = Hash(UInt64, String).new
      end
    end
  end
end
