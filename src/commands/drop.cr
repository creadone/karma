module Karma
  module Commands
    module Drop

      def self.call(directive, cluster)
        name = directive.tree_name.not_nil!
        if cluster.delete(name)
          "OK"
        else
          raise "Tree \"#{name}\" not exists"
        end
      end

    end
  end
end