module Karma
  module Commands
    module Decrement
      def self.call(directive, cluster)
        cluster.pick(directive.series_name) do |tree|
          if directive.date || directive.value
            return tree.decrement(directive.key_value, directive.write_bucket.value, directive.write_value)
          end

          return tree.decrement(directive.key_value)
        end
      end
    end
  end
end
