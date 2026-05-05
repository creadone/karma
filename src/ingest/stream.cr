module Karma
  module Ingest
    class Stream
      getter stream_id : String
      getter mode : String
      getter granularity : String?
      property last_chunk_seq : UInt64
      property series_name : String?
      property staged_tree : CounterTree::Tree?

      def initialize(@stream_id : String, @mode : String, @granularity : String?)
        @last_chunk_seq = 0_u64
      end
    end
  end
end
