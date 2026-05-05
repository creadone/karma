module Karma
  module Commands
    module Increment

      def self.call(directive, cluster)
        series = directive.series
        key = directive.series_key
        cluster.pick(series.name) do |tree|
          if directive.date || directive.value
            return tree.increment(key.value, directive.write_bucket.value, directive.write_value)
          end

          return tree.increment(key.value)
        end
      end

    end
  end
end
