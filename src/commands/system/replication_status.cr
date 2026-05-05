module Karma
  module Commands
    module ReplicationStatus
      def self.call(directive, cluster)
        snapshot = Karma::Backup.info(Karma.config.dump_dir)
        recovery = Karma::Recovery.status
        replication = Karma::Replication.status

        {
          role:                           Karma.config.role,
          wal_enabled:                    Karma::Wal.enabled?,
          wal_current_lsn:                Karma::Wal.current_lsn,
          wal_bytes:                      snapshot[:wal_bytes],
          replayed_lsn:                   replication[:replayed_lsn],
          replication_lag_entries:        replication[:lag_entries],
          replication_entries_applied:    replication[:entries_applied],
          replication_last_received_unix: replication[:last_received_unix],
          last_snapshot_lsn:              snapshot[:last_snapshot_lsn],
          latest_snapshots:               snapshot[:latest_by_tree],
          recovery:                       recovery,
          recovery_checkpoint_count:      recovery[:checkpoint_count],
        }
      end
    end
  end
end
