module Karma
  module Commands
    module Load
      def self.call(directive, cluster)
        dump_name = directive.tree_name.not_nil!

        dump_dir = File.expand_path(Karma.config.dump_dir)
        tree_name = Karma::Backup.dump_tree_name(dump_name)
        dump_path = File.join(dump_dir, dump_name)

        if Karma::Backup.load(cluster, dump_path, tree_name)
          if Karma.config.role == "slave"
            metadata = Karma::Backup.snapshot_metadata(dump_path)
            Karma::Replication.checkpoint(metadata.last_lsn, dump_dir) if metadata.last_lsn > 0
          end

          "Tree \"#{tree_name}\" loaded"
        end
      end
    end
  end
end
