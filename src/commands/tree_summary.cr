module Karma
  module Commands
    module TreeSummary
      def self.call(directive, cluster)
        range = if directive.time_from.nil? && directive.time_to.nil?
                  nil
                else
                  directive.bucket_range
                end
        cluster.tree_summary(directive.series.name, range)
      end
    end
  end
end
