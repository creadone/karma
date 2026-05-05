module Karma
  module Commands
    module BatchSum
      def self.call(directive, cluster)
        series = directive.series
        tree = cluster.get(series.name)
        keys = directive.keys.not_nil!

        keys.map do |key|
          value = if directive.time_from.nil? && directive.time_to.nil?
                    tree.sum(key)
                  else
                    range = directive.bucket_range
                    tree.sum(key, range.from.value, range.to.value)
                  end

          {key: key, value: value}
        end
      end
    end
  end
end
