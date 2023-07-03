module Karma
  module Commands
    module Reset

      def self.call(directive, cluster)
        name = directive.tree_name.not_nil!
        cluster.pick(name) do |tree|
          unless directive.key.nil?
            return "OK" if tree.reset(directive.key.as(UInt64))
          else
            return "OK" if tree.reset
          end
        end
      end

    end
  end
end