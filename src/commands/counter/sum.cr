module Karma
  module Commands
    module Sum
      def self.call(directive, cluster)
        tree = cluster.get(directive.series_name)

        if range = directive.bucket_range?
          return tree.sum(
            directive.key_value,
            range.from.value,
            range.to.value
          )
        end

        tree.sum(directive.key_value)
      end
    end
  end
end
