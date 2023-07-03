module Karma
  module Commands
    module Sum

      def self.call(directive, cluster)
        name = directive.tree_name.not_nil!

        cluster.pick(name) do |tree|
          unless directive.time_from.nil? && directive.time_to.nil?
            return tree.sum(
              directive.key.as(UInt64),
              directive.time_from.as(UInt64),
              directive.time_to.as(UInt64)
            )
          else
            return tree.sum(directive.key.as(UInt64))
          end
        end
      end

    end
  end
end