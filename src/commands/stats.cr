module Karma
  module Commands
    module Stats
      def self.call(directive, cluster)
        Karma::Operations.stats(cluster)
      end
    end
  end
end
