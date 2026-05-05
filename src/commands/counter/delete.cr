module Karma
  module Commands
    module Delete
      def self.call(directive, cluster)
        range = directive.bucket_range
        cluster.pick(directive.series_name) do |tree|
          if directive.keyed?
            return tree.delete(
              directive.key_value,
              range.from.value,
              range.to.value
            )
          end

          return tree.delete(
            range.from.value,
            range.to.value
          )
        end
      end
    end
  end
end
