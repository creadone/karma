module Karma
  module Commands
    module IdempotencySnapshotFetchChunk
      def self.call(directive, cluster)
        Karma::Idempotency.fetch_chunk(
          directive.cursor || 0_u64,
          directive.limit || Karma::Backup::SNAPSHOT_CHUNK_DEFAULT_BYTES
        )
      end
    end
  end
end
