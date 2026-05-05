module Karma
  module Commands
    module Delete

      def self.call(directive, cluster)
        series = directive.series
        range = directive.bucket_range
        cluster.pick(series.name) do |tree|
          unless directive.key.nil?
            key = directive.series_key
            return tree.delete(
              key.value,
              range.from.value,
              range.to.value
            )
          else
            return tree.delete(
              range.from.value,
              range.to.value
            )
          end
        end
      end

    end
  end
end
