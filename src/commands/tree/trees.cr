module Karma
  module Commands
    module Trees

      def self.call(directive, cluster)
        cluster.trees.keys
      end

    end
  end
end