module Karma
  module Commands
    module Find
      def self.call(directive, cluster)
        range = directive.bucket_range
        tree = cluster.get(directive.series_name)

        if directive.keyed?
          return tree.find(
            directive.key_value,
            range.from.value,
            range.to.value
          )
        end

        cluster.tree_series(directive.series_name, range)
      end
    end
  end
end
