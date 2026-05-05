module Karma
  module Commands
    module Dumps
      def self.call(directive, cluster)
        Karma::Backup.dumps(Karma.config.dump_dir)
      end
    end
  end
end
