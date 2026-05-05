module Karma
  module Commands
    module Create

      def self.call(directive, cluster)
        name = directive.tree_name.not_nil!
        if cluster.create(name)
          "OK"
        else
          raise "Cannot create tree with name #{name}"
        end
      end

    end
  end
end