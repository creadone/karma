module Karma
  module Commands
    module ReplicationEntries
      def self.call(directive, cluster)
        limit = directive.limit || 1_000
        entries = Karma::Wal.entries_after(
          directive.after_lsn.not_nil!,
          limit
        )

        {
          after_lsn: directive.after_lsn.not_nil!,
          limit:     limit,
          count:     entries.size,
          entries:   entries.map(&.to_response),
          next_lsn:  entries.empty? ? directive.after_lsn.not_nil! : entries.last.lsn,
        }
      end
    end
  end
end
