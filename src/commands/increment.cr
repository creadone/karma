module Karma
  module Commands
    module Increment

      def self.call(directive, cluster)
        name = directive.tree_name.not_nil!
        key  = directive.key.not_nil!
        cluster.pick(name) do |tree|
          return tree.increment(key)
        end
      end

    end
  end
end