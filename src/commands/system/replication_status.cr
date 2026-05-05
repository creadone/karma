module Karma
  module Commands
    module ReplicationStatus
      def self.call(directive, cluster)
        snapshot = Karma::Backup.info(Karma.config.dump_dir)
        recovery = Karma::Recovery.status

        {
          role:                      Karma.config.role,
          wal_enabled:               Karma::Wal.enabled?,
          wal_current_lsn:           Karma::Wal.current_lsn,
          wal_bytes:                 snapshot[:wal_bytes],
          last_snapshot_lsn:         snapshot[:last_snapshot_lsn],
          latest_snapshots:          snapshot[:latest_by_tree],
          recovery:                  recovery,
          recovery_checkpoint_count: recovery[:checkpoint_count],
        }
      end
    end
  end
end
