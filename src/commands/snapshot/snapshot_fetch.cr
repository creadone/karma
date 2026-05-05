module Karma
  module Commands
    module SnapshotFetch
      def self.call(directive, cluster)
        dump_name = directive.tree_name.not_nil!
        dump_dir = File.expand_path(Karma.config.dump_dir)
        dump_path = File.join(dump_dir, dump_name)

        Karma::Backup.fetch(dump_path)
      end
    end
  end
end
