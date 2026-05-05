module Karma
  module Commands
    module TreeInfo
      def self.call(directive, cluster)
        cluster.tree_info(directive.series_name)
      end
    end
  end
end
