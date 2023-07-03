module Karma
  module Commands
    module Load

      def self.call(directive, cluster)
        dump_name = directive.tree_name.not_nil!

        dump_dir  = File.expand_path(Karma.config.dump_dir)
        tree_name = File.basename(dump_name.split("_").last, ".tree")
        dump_path = File.join(dump_dir, dump_name)

        if Karma::Backup.load(cluster, dump_path, tree_name)
          "Tree \"#{tree_name}\" loaded"
        end
      end

    end
  end
end