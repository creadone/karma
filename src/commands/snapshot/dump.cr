module Karma
  module Commands
    module Dump

      def self.call(directive, cluster)
        tree_name = directive.tree_name.not_nil!

        dump_dir  = File.expand_path(Karma.config.dump_dir)
        dump_name = "#{Time.local.to_unix}_#{tree_name}.tree"
        dump_path = File.join(dump_dir, dump_name)
        Dir.mkdir_p(dump_dir) unless Dir.exists?(dump_dir)

        if Karma::Backup.dump(cluster, dump_path, tree_name)
          "Tree \"#{tree_name}\" saved"
        end
      end

    end
  end
end