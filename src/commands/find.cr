module Karma
  module Commands
    module Find
      def self.call(directive, cluster)
        series = directive.series
        range = directive.bucket_range
        tree = cluster.get(series.name)

        unless directive.key.nil?
          key = directive.series_key
          return tree.find(
            key.value,
            range.from.value,
            range.to.value
          )
        else
          return tree.find(
            range.from.value,
            range.to.value
          )
        end
      end
    end
  end
end
