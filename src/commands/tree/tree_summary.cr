module Karma
  module Commands
    module TreeSummary
      def self.call(directive, cluster)
        cluster.tree_summary(directive.series_name, directive.bucket_range?)
      end
    end
  end
end
