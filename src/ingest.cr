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

    SUPPORTED_MODES = %w[add set replace_series]

    @@streams = Hash(String, Stream).new
    @@metrics_mutex = Mutex.new
    @@chunks_applied = 0_i64
    @@chunks_skipped = 0_i64
    @@chunks_rejected = 0_i64
    @@items_applied = 0_i64
    @@total_latency_ms = 0.0
    @@last_latency_ms = 0.0

    def self.begin_stream(stream_id : String, mode : String, granularity : String?)
      unless SUPPORTED_MODES.includes?(mode)
        raise Karma::Error.new("validation_error", "Unsupported ingest mode #{mode}")
      end

      if stream = @@streams[stream_id]?
        raise Karma::Error.new("validation_error", "Ingest stream already exists with mode #{stream.mode}") unless stream.mode == mode

        return stream_status(stream)
      end

      stream = Stream.new(stream_id, mode, granularity)
      @@streams[stream_id] = stream
      stream_status(stream)
    end

    def self.chunk_status(stream_id : String, chunk_seq : UInt64)
      stream = validate_chunk!(stream_id, chunk_seq)

      if chunk_seq <= stream.last_chunk_seq
        return {stream_id: stream.stream_id, chunk_seq: chunk_seq, skipped: true}
      end

      unless chunk_seq == stream.last_chunk_seq + 1_u64
        raise Karma::Error.new("validation_error", "Field chunk_seq must be the next chunk")
      end

      {stream_id: stream.stream_id, chunk_seq: chunk_seq, skipped: false}
    end

    def self.validate_chunk!(stream_id : String, chunk_seq : UInt64) : Stream
      stream = stream!(stream_id)
      raise Karma::Error.new("validation_error", "Field chunk_seq must be greater than 0") if chunk_seq == 0_u64
      return stream if chunk_seq <= stream.last_chunk_seq

      unless chunk_seq == stream.last_chunk_seq + 1_u64
        raise Karma::Error.new("validation_error", "Field chunk_seq must be the next chunk")
      end

      stream
    end

    def self.validate_stream_exists!(stream_id : String) : Stream
      stream!(stream_id)
    end

    def self.mark_chunk(stream_id : String, chunk_seq : UInt64)
      stream = stream!(stream_id)
      stream.last_chunk_seq = chunk_seq
      {stream_id: stream.stream_id, chunk_seq: chunk_seq, last_chunk_seq: stream.last_chunk_seq}
    end

    def self.bind_series!(stream : Stream, series_name : String) : Stream
      if existing = stream.series_name
        unless existing == series_name
          raise Karma::Error.new("validation_error", "Ingest stream is already bound to series #{existing}")
        end
      else
        stream.series_name = series_name
      end

      stream
    end

    def self.record_chunk(applied : Bool, skipped : Bool, item_count : Int32, latency_ms : Float64) : Nil
      @@metrics_mutex.synchronize do
        if skipped
          @@chunks_skipped += 1
        elsif applied
          @@chunks_applied += 1
          @@items_applied += item_count
        else
          @@chunks_rejected += 1
        end

        @@total_latency_ms += latency_ms
        @@last_latency_ms = latency_ms
      end
    end

    def self.record_rejected_chunk : Nil
      @@metrics_mutex.synchronize do
        @@chunks_rejected += 1
      end
    end

    def self.metrics
      @@metrics_mutex.synchronize do
        {
          active_streams:     @@streams.size,
          chunks_applied:     @@chunks_applied,
          chunks_skipped:     @@chunks_skipped,
          chunks_rejected:    @@chunks_rejected,
          items_applied:      @@items_applied,
          latency_ms_last:    @@last_latency_ms,
          latency_ms_average: @@chunks_applied + @@chunks_skipped + @@chunks_rejected == 0 ? 0.0 : @@total_latency_ms / (@@chunks_applied + @@chunks_skipped + @@chunks_rejected),
        }
      end
    end

    def self.commit(stream_id : String, cluster)
      stream = stream!(stream_id)
      if stream.mode == "replace_series"
        series_name = stream.series_name || raise Karma::Error.new("validation_error", "Cannot commit empty replace_series stream")
        staged_tree = stream.staged_tree || CounterTree::Tree.new
        cluster.replace(series_name, staged_tree)
      end
      @@streams.delete(stream_id)
      {stream_id: stream.stream_id, status: "committed", last_chunk_seq: stream.last_chunk_seq}
    end

    def self.abort(stream_id : String)
      stream = stream!(stream_id)
      @@streams.delete(stream_id)
      {stream_id: stream.stream_id, status: "aborted", last_chunk_seq: stream.last_chunk_seq}
    end

    def self.reset! : Nil
      @@streams.clear
      @@metrics_mutex.synchronize do
        @@chunks_applied = 0_i64
        @@chunks_skipped = 0_i64
        @@chunks_rejected = 0_i64
        @@items_applied = 0_i64
        @@total_latency_ms = 0.0
        @@last_latency_ms = 0.0
      end
    end

    private def self.stream!(stream_id : String) : Stream
      @@streams[stream_id]? || raise Karma::Error.new("not_found", "Ingest stream \"#{stream_id}\" not found")
    end

    private def self.stream_status(stream : Stream)
      {
        stream_id:      stream.stream_id,
        mode:           stream.mode,
        series:         stream.series_name,
        granularity:    stream.granularity,
        status:         "active",
        last_chunk_seq: stream.last_chunk_seq,
      }
    end
  end
end
