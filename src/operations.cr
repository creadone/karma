module Karma
  module Operations
    STARTED_AT    = Time.monotonic
    METRICS_MUTEX = Mutex.new
    @@command_count = 0_i64
    @@error_count = 0_i64
    @@legacy_request_count = 0_i64
    @@query_timeout_count = 0_i64
    @@batch_read_count = 0_i64
    @@batch_read_key_count = 0_i64
    @@batch_write_count = 0_i64
    @@batch_write_item_count = 0_i64
    @@retention_count = 0_i64
    @@compact_count = 0_i64
    @@total_latency_ms = 0.0
    @@last_latency_ms = 0.0

    def self.record_legacy_request : Nil
      METRICS_MUTEX.synchronize do
        @@legacy_request_count += 1
      end
    end

    def self.record_query_timeout : Nil
      METRICS_MUTEX.synchronize do
        @@query_timeout_count += 1
      end
    end

    def self.record_batch_read(key_count : Int32) : Nil
      METRICS_MUTEX.synchronize do
        @@batch_read_count += 1
        @@batch_read_key_count += key_count
      end
    end

    def self.record_batch_write(item_count : Int32) : Nil
      METRICS_MUTEX.synchronize do
        @@batch_write_count += 1
        @@batch_write_item_count += item_count
      end
    end

    def self.record_retention : Nil
      METRICS_MUTEX.synchronize do
        @@retention_count += 1
      end
    end

    def self.record_compact : Nil
      METRICS_MUTEX.synchronize do
        @@compact_count += 1
      end
    end

    def self.record_command(success : Bool, latency_ms : Float64) : Nil
      METRICS_MUTEX.synchronize do
        @@command_count += 1
        @@error_count += 1 unless success
        @@total_latency_ms += latency_ms
        @@last_latency_ms = latency_ms
      end
    end

    private def self.uptime_seconds : Float64
      (Time.monotonic - STARTED_AT).total_seconds
    end

    private def self.wal_bytes : Int64
      wal_path = Karma::Wal.path
      File.exists?(wal_path) ? File.size(wal_path) : 0_i64
    end

    private def self.command_count : Int64
      METRICS_MUTEX.synchronize { @@command_count }
    end

    private def self.error_count : Int64
      METRICS_MUTEX.synchronize { @@error_count }
    end

    private def self.legacy_request_count : Int64
      METRICS_MUTEX.synchronize { @@legacy_request_count }
    end

    private def self.query_timeout_count : Int64
      METRICS_MUTEX.synchronize { @@query_timeout_count }
    end

    private def self.batch_read_count : Int64
      METRICS_MUTEX.synchronize { @@batch_read_count }
    end

    private def self.batch_read_key_count : Int64
      METRICS_MUTEX.synchronize { @@batch_read_key_count }
    end

    private def self.batch_write_count : Int64
      METRICS_MUTEX.synchronize { @@batch_write_count }
    end

    private def self.batch_write_item_count : Int64
      METRICS_MUTEX.synchronize { @@batch_write_item_count }
    end

    private def self.retention_count : Int64
      METRICS_MUTEX.synchronize { @@retention_count }
    end

    private def self.compact_count : Int64
      METRICS_MUTEX.synchronize { @@compact_count }
    end

    private def self.last_latency_ms : Float64
      METRICS_MUTEX.synchronize { @@last_latency_ms }
    end

    private def self.average_latency_ms : Float64
      METRICS_MUTEX.synchronize do
        @@command_count.zero? ? 0.0 : @@total_latency_ms / @@command_count
      end
    end
  end
end

require "./operations/stats"
require "./operations/prometheus"
