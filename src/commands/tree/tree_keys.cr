module Karma
  module Commands
    module TreeKeys
      def self.call(directive, cluster)
        cluster.tree_keys(
          directive.series_name,
          directive.limit.not_nil!,
          directive.cursor
        )
      end
    end
  end
end
