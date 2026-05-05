module Karma
  module Commands
    module ReplicationStatus
      def self.call(directive, cluster)
        snapshot = Karma::Backup.info(Karma.config.dump_dir)
        recovery = Karma::Recovery.status
        replication = Karma::Replication.status

        {
          role:                                    Karma.config.role,
          wal_enabled:                             Karma::Wal.enabled?,
          wal_current_lsn:                         Karma::Wal.current_lsn,
          wal_bytes:                               snapshot[:wal_bytes],
          replayed_lsn:                            replication[:replayed_lsn],
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
          last_snapshot_lsn:                       snapshot[:last_snapshot_lsn],
          latest_snapshots:                        snapshot[:latest_by_tree],
          recovery:                                recovery,
          recovery_checkpoint_count:               recovery[:checkpoint_count],
        }
      end
    end
  end
end
