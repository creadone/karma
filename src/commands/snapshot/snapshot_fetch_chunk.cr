module Karma
  module Commands
    module SnapshotFetchChunk
      def self.call(directive, cluster)
        dump_name = directive.tree_name.not_nil!
        dump_dir = File.expand_path(Karma.config.dump_dir)
        dump_path = File.join(dump_dir, dump_name)
        offset = directive.cursor || 0_u64
        limit = directive.limit || Karma::Backup::SNAPSHOT_CHUNK_DEFAULT_BYTES

        Karma::Backup.fetch_chunk(dump_path, offset, limit)
      end
    end
  end
end
