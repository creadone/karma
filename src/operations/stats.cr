module Karma
  module Operations
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

    def self.verify_restore
      Karma::Backup.verify(Karma.config.dump_dir)
    end
  end
end
