module Karma
  module Commands
    module Reset
      def self.call(directive, cluster)
        cluster.pick(directive.series_name) do |tree|
          return "OK" if directive.keyed? ? tree.reset(directive.key_value) : tree.reset
        end
      end
    end
  end
end
