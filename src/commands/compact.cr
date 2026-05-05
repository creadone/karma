module Karma
  module Commands
    module Compact
      def self.call(directive, cluster)
        if directive.tree_name
          cluster.compact(directive.series.name)
        else
          cluster.compact
        end
        Karma::Operations.record_compact
        "OK"
      end
    end
  end
end
