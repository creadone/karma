module Karma
  module Commands
    module ReplicationEntries
      RESPONSE_OVERHEAD_BYTES = 2_048

      def self.call(directive, cluster)
        limit = directive.limit || 1_000
        page = Karma::Wal.entries_page_after(
          directive.after_lsn.not_nil!,
          limit,
          max_bytes: entry_budget_bytes
        )
        entries = page.entries

        {
          after_lsn:          directive.after_lsn.not_nil!,
          limit:              limit,
          byte_limit:         entry_budget_bytes,
          entries_bytes:      page.bytes,
          truncated_by_bytes: page.truncated_by_bytes,
          count:              entries.size,
          source_lsn:         Karma::Wal.current_lsn,
          entries:            entries.map(&.to_response),
          next_lsn:           entries.empty? ? directive.after_lsn.not_nil! : entries.last.lsn,
        }
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
