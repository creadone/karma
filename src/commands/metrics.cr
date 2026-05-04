module Karma
  module Commands
    module Metrics
      def self.call(directive, cluster)
        Karma::Operations.metrics(cluster)
      end
    end
  end
end
