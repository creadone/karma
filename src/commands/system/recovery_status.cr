module Karma
  module Commands
    module RecoveryStatus
      def self.call(directive, cluster)
        Karma::Recovery.status(directive.source)
      end
    end
  end
end
