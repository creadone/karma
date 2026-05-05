module Karma
  module Commands
    module TreeTop
      def self.call(directive, cluster)
        range = if directive.time_from.nil? && directive.time_to.nil?
                  nil
                else
                  directive.bucket_range
                end
        cluster.tree_top(directive.series.name, directive.limit.not_nil!, range)
      end
    end
  end
end
