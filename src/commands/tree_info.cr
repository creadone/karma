module Karma
  module Commands
    module TreeInfo
      def self.call(directive, cluster)
        cluster.tree_info(directive.series.name)
      end
    end
  end
end
