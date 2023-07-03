module Karma
  module Commands
    module Find

      def self.call(directive, cluster)
        name = directive.tree_name.not_nil!
        cluster.pick(name) do |tree|
          unless directive.key.nil?
            return tree.find(
              directive.key.as(UInt64),
              directive.time_from.as(UInt64),
              directive.time_to.as(UInt64)
            )
          else
            return tree.find(
              directive.time_from.as(UInt64),
              directive.time_to.as(UInt64)
            )
          end
        end
      end

    end
  end
end