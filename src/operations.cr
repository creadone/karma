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

    def self.health
      {
        status:         "ok",
        uptime_seconds: uptime_seconds,
        wal_enabled:    Karma::Wal.enabled?,
      }
    end

    def self.stats(cluster : Cluster)
      ingest_metrics = Karma::Ingest.metrics
      {
        uptime_seconds:         uptime_seconds,
        trees:                  cluster.tree_count,
        keys:                   cluster.key_count,
        dump_count:             Karma::Backup.dumps(Karma.config.dump_dir).size,
        wal_enabled:            Karma::Wal.enabled?,
        wal_bytes:              wal_bytes,
        memory_bytes:           GC.stats.heap_size,
        command_count:          command_count,
        error_count:            error_count,
        legacy_request_count:   legacy_request_count,
        query_timeout_count:    query_timeout_count,
        batch_read_count:       batch_read_count,
        batch_read_key_count:   batch_read_key_count,
        batch_write_count:      batch_write_count,
        batch_write_item_count: batch_write_item_count,
        retention_count:        retention_count,
        compact_count:          compact_count,
        latency_ms_avg:         average_latency_ms,
        latency_ms_last:        last_latency_ms,
        ingest_active_streams:  ingest_metrics[:active_streams],
        ingest_chunks_applied:  ingest_metrics[:chunks_applied],
        ingest_chunks_skipped:  ingest_metrics[:chunks_skipped],
        ingest_chunks_rejected: ingest_metrics[:chunks_rejected],
        ingest_items_applied:   ingest_metrics[:items_applied],
        ingest_latency_ms_last: ingest_metrics[:latency_ms_last],
        ingest_latency_ms_avg:  ingest_metrics[:latency_ms_average],
      }
    end

    def self.metrics(cluster : Cluster) : String
      String.build do |io|
        io << "# TYPE karma_uptime_seconds gauge\n"
        io << "karma_uptime_seconds #{uptime_seconds}\n"
        io << "# TYPE karma_trees gauge\n"
        io << "karma_trees #{cluster.tree_count}\n"
        io << "# TYPE karma_keys gauge\n"
        io << "karma_keys #{cluster.key_count}\n"
        io << "# TYPE karma_dumps gauge\n"
        io << "karma_dumps #{Karma::Backup.dumps(Karma.config.dump_dir).size}\n"
        io << "# TYPE karma_wal_bytes gauge\n"
        io << "karma_wal_bytes #{wal_bytes}\n"
        io << "# TYPE karma_memory_bytes gauge\n"
        io << "karma_memory_bytes #{GC.stats.heap_size}\n"
        io << "# TYPE karma_commands_total counter\n"
        io << "karma_commands_total #{command_count}\n"
        io << "# TYPE karma_errors_total counter\n"
        io << "karma_errors_total #{error_count}\n"
        io << "# TYPE karma_protocol_v1_requests_total counter\n"
        io << "karma_protocol_v1_requests_total #{legacy_request_count}\n"
        io << "# TYPE karma_query_timeouts_total counter\n"
        io << "karma_query_timeouts_total #{query_timeout_count}\n"
        io << "# TYPE karma_batch_reads_total counter\n"
        io << "karma_batch_reads_total #{batch_read_count}\n"
        io << "# TYPE karma_batch_read_keys_total counter\n"
        io << "karma_batch_read_keys_total #{batch_read_key_count}\n"
        io << "# TYPE karma_batch_writes_total counter\n"
        io << "karma_batch_writes_total #{batch_write_count}\n"
        io << "# TYPE karma_batch_write_items_total counter\n"
        io << "karma_batch_write_items_total #{batch_write_item_count}\n"
        io << "# TYPE karma_retention_operations_total counter\n"
        io << "karma_retention_operations_total #{retention_count}\n"
        io << "# TYPE karma_compactions_total counter\n"
        io << "karma_compactions_total #{compact_count}\n"
        io << "# TYPE karma_command_latency_ms gauge\n"
        io << "karma_command_latency_ms #{last_latency_ms}\n"
        io << "# TYPE karma_command_latency_ms_average gauge\n"
        io << "karma_command_latency_ms_average #{average_latency_ms}\n"
        ingest_metrics = Karma::Ingest.metrics
        io << "# TYPE karma_ingest_active_streams gauge\n"
        io << "karma_ingest_active_streams #{ingest_metrics[:active_streams]}\n"
        io << "# TYPE karma_ingest_chunks_applied_total counter\n"
        io << "karma_ingest_chunks_applied_total #{ingest_metrics[:chunks_applied]}\n"
        io << "# TYPE karma_ingest_chunks_skipped_total counter\n"
        io << "karma_ingest_chunks_skipped_total #{ingest_metrics[:chunks_skipped]}\n"
        io << "# TYPE karma_ingest_chunks_rejected_total counter\n"
        io << "karma_ingest_chunks_rejected_total #{ingest_metrics[:chunks_rejected]}\n"
        io << "# TYPE karma_ingest_items_applied_total counter\n"
        io << "karma_ingest_items_applied_total #{ingest_metrics[:items_applied]}\n"
        io << "# TYPE karma_ingest_chunk_latency_ms gauge\n"
        io << "karma_ingest_chunk_latency_ms #{ingest_metrics[:latency_ms_last]}\n"
        io << "# TYPE karma_ingest_chunk_latency_ms_average gauge\n"
        io << "karma_ingest_chunk_latency_ms_average #{ingest_metrics[:latency_ms_average]}\n"
      end
    end

    def self.verify_restore
      Karma::Backup.verify(Karma.config.dump_dir)
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
