module Karma
  module Commands
    module TreeTop
      def self.call(directive, cluster)
        cluster.tree_top(directive.series_name, directive.limit.not_nil!, directive.bucket_range?)
      end
    end
  end
end
