module Karma
  module Ingest
    @@metrics_mutex = Mutex.new
    @@chunks_applied = 0_i64
    @@chunks_skipped = 0_i64
    @@chunks_rejected = 0_i64
    @@items_applied = 0_i64
    @@total_latency_ms = 0.0
    @@last_latency_ms = 0.0

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
          active_streams:     active_stream_count,
          chunks_applied:     @@chunks_applied,
          chunks_skipped:     @@chunks_skipped,
          chunks_rejected:    @@chunks_rejected,
          items_applied:      @@items_applied,
          latency_ms_last:    @@last_latency_ms,
          latency_ms_average: total_event_count == 0 ? 0.0 : @@total_latency_ms / total_event_count,
        }
      end
    end

    private def self.reset_metrics! : Nil
      @@metrics_mutex.synchronize do
        @@chunks_applied = 0_i64
        @@chunks_skipped = 0_i64
        @@chunks_rejected = 0_i64
        @@items_applied = 0_i64
        @@total_latency_ms = 0.0
        @@last_latency_ms = 0.0
      end
    end

    private def self.total_event_count : Int64
      @@chunks_applied + @@chunks_skipped + @@chunks_rejected
    end
  end
end
