module Karma
  module Commands
    module SnapshotInfo
      def self.call(directive, cluster)
        Karma::Backup.info(Karma.config.dump_dir)
      end
    end
  end
end
