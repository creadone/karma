module Karma
  module Commands
    module Drop
      def self.call(directive, cluster)
        name = directive.tree_name.not_nil!
        if cluster.delete(name)
          "OK"
        else
          raise Karma::Error.new("not_found", "Tree \"#{name}\" not found")
        end
      end
    end
  end
end
