module Karma
  module Operations
    def self.health
      {
        status:         "ok",
        uptime_seconds: uptime_seconds,
        role:           Karma.config.role,
        wal_enabled:    Karma::Wal.enabled?,
      }
    end

    def self.stats(cluster : Cluster)
      ingest_metrics = Karma::Ingest.metrics
      idempotency_metrics = Karma::Idempotency.metrics
      replication = Karma::Replication.status
      {
        uptime_seconds:                          uptime_seconds,
        trees:                                   cluster.tree_count,
        keys:                                    cluster.key_count,
        dump_count:                              Karma::Backup.dumps(Karma.config.dump_dir).size,
        role:                                    Karma.config.role,
        wal_enabled:                             Karma::Wal.enabled?,
        wal_bytes:                               wal_bytes,
        wal_current_lsn:                         Karma::Wal.current_lsn,
        replication_replayed_lsn:                replication[:replayed_lsn],
        replication_lag_entries:                 replication[:lag_entries],
        replication_entries_applied:             replication[:entries_applied],
        replication_last_received_unix:          replication[:last_received_unix],
        replication_poll_attempt_count:          replication[:poll_attempt_count],
        replication_poll_success_count:          replication[:poll_success_count],
        replication_poll_error_count:            replication[:poll_error_count],
        replication_last_poll_attempt_unix:      replication[:last_poll_attempt_unix],
        replication_last_poll_success_unix:      replication[:last_poll_success_unix],
        replication_last_poll_error_unix:        replication[:last_poll_error_unix],
        replication_last_poll_error:             replication[:last_poll_error],
        replication_bootstrap_attempt_count:     replication[:bootstrap_attempt_count],
        replication_bootstrap_success_count:     replication[:bootstrap_success_count],
        replication_bootstrap_error_count:       replication[:bootstrap_error_count],
        replication_last_bootstrap_attempt_unix: replication[:last_bootstrap_attempt_unix],
        replication_last_bootstrap_success_unix: replication[:last_bootstrap_success_unix],
        replication_last_bootstrap_error_unix:   replication[:last_bootstrap_error_unix],
        replication_last_bootstrap_error:        replication[:last_bootstrap_error],
        memory_bytes:                            GC.stats.heap_size,
        command_count:                           command_count,
        error_count:                             error_count,
        legacy_request_count:                    legacy_request_count,
        query_timeout_count:                     query_timeout_count,
        batch_read_count:                        batch_read_count,
        batch_read_key_count:                    batch_read_key_count,
        batch_write_count:                       batch_write_count,
        batch_write_item_count:                  batch_write_item_count,
        retention_count:                         retention_count,
        compact_count:                           compact_count,
        reconciliation_run_count:                reconciliation_run_count,
        reconciliation_checked_points:           reconciliation_checked_points,
        reconciliation_mismatch_count:           reconciliation_mismatch_count,
        reconciliation_absolute_drift:           reconciliation_absolute_drift,
        reconciliation_last_run_unix:            reconciliation_last_run_unix,
        reconciliation_last_checked_points:      reconciliation_last_checked_points,
        reconciliation_last_mismatch_count:      reconciliation_last_mismatch_count,
        reconciliation_last_absolute_drift:      reconciliation_last_absolute_drift,
        reconciliation_last_max_abs_delta:       reconciliation_last_max_abs_delta,
        recovery_checkpoint_count:               Karma::Recovery.checkpoint_count,
        recovery_last_checkpoint_unix:           Karma::Recovery.last_checkpoint_unix,
        latency_ms_avg:                          average_latency_ms,
        latency_ms_last:                         last_latency_ms,
        ingest_active_streams:                   ingest_metrics[:active_streams],
        ingest_chunks_applied:                   ingest_metrics[:chunks_applied],
        ingest_chunks_skipped:                   ingest_metrics[:chunks_skipped],
        ingest_chunks_rejected:                  ingest_metrics[:chunks_rejected],
        ingest_items_applied:                    ingest_metrics[:items_applied],
        ingest_latency_ms_last:                  ingest_metrics[:latency_ms_last],
        ingest_latency_ms_avg:                   ingest_metrics[:latency_ms_average],
        idempotency_record_count:                idempotency_metrics[:record_count],
        idempotency_hits:                        idempotency_metrics[:hits],
        idempotency_conflicts:                   idempotency_metrics[:conflicts],
        idempotency_pruned:                      idempotency_metrics[:pruned],
        idempotency_write_count:                 idempotency_metrics[:write_count],
        idempotency_write_latency_ms_last:       idempotency_metrics[:write_latency_ms_last],
        idempotency_write_latency_ms_avg:        idempotency_metrics[:write_latency_ms_avg],
        idempotency_committed_stream_count:      idempotency_metrics[:committed_stream_count],
      }
    end

    def self.verify_restore
      Karma::Backup.verify(Karma.config.dump_dir)
    end
  end
end
