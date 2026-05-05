module Karma
  module Backup
    def self.verify(dump_dir)
      cluster = Cluster.restore_with_wal(dump_dir)
      cluster.validate!
      {
        status:     "ok",
        dump_count: dumps(dump_dir).size,
        trees:      cluster.tree_count,
        keys:       cluster.key_count,
      }
    end

    def self.info(dump_dir)
      dump_paths = dumps(dump_dir)
      latest_by_tree = dump_paths.group_by { |path| dump_tree_name(path) }.map do |tree_name, paths|
        latest = paths.max_by { |path| dump_timestamp(path) }
        {
          tree:      tree_name,
          file:      File.basename(latest),
          timestamp: dump_timestamp(latest),
          bytes:     File.size(latest),
        }
      end

      wal_path = Karma::Wal.path(dump_dir)
      {
        dump_count:              dump_paths.size,
        latest_by_tree:          latest_by_tree,
        wal_enabled:             Karma::Wal.enabled?,
        wal_bytes:               File.exists?(wal_path) ? File.size(wal_path) : 0_i64,
        dump_retention_per_tree: Karma.config.dump_retention_per_tree,
      }
    end
  end
end
