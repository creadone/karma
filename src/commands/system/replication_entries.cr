module Karma
  module Commands
    module ReplicationEntries
      RESPONSE_OVERHEAD_BYTES = 2_048

      def self.call(directive, cluster)
        after_lsn = directive.after_lsn.not_nil!
        ensure_not_compacted!(after_lsn)

        limit = directive.limit || 1_000
        page = Karma::Wal.entries_page_after(
          after_lsn,
          limit,
          max_bytes: entry_budget_bytes
        )
        entries = page.entries

        {
          after_lsn:          after_lsn,
          limit:              limit,
          byte_limit:         entry_budget_bytes,
          entries_bytes:      page.bytes,
          truncated_by_bytes: page.truncated_by_bytes,
          count:              entries.size,
          source_lsn:         Karma::Wal.current_lsn,
          entries:            entries.map(&.to_response),
          next_lsn:           entries.empty? ? after_lsn : entries.last.lsn,
        }
      end

      private def self.ensure_not_compacted!(after_lsn : UInt64) : Nil
        snapshot_lsn = Karma::Backup.restore_lsn(Karma.config.dump_dir)
        return if snapshot_lsn == 0_u64
        return if after_lsn >= snapshot_lsn

        raise Karma::Error.new(
          "replication_gap",
          "Requested WAL after_lsn #{after_lsn} is older than snapshot LSN #{snapshot_lsn}; bootstrap from snapshot"
        )
      end

      private def self.entry_budget_bytes : Int32?
        max_response_bytes = Karma.config.max_response_bytes
        return nil if max_response_bytes <= 0

        budget = max_response_bytes - RESPONSE_OVERHEAD_BYTES
        budget > 0 ? budget : max_response_bytes
      end
    end
  end
end
