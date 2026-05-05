module Karma
  module Commands
    module Sum
      def self.call(directive, cluster)
        series = directive.series
        key = directive.series_key
        tree = cluster.get(series.name)

        unless directive.time_from.nil? && directive.time_to.nil?
          range = directive.bucket_range
          return tree.sum(
            key.value,
            range.from.value,
            range.to.value
          )
        else
          return tree.sum(key.value)
        end
      end
    end
  end
end
