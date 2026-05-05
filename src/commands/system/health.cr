module Karma
  module Commands
    module Health
      def self.call(directive, cluster)
        Karma::Operations.health
      end
    end
  end
end
