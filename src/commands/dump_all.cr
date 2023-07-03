module Karma
  module Commands
    module DumpAll

      def self.call(directive, cluster)
        spawn cluster.dump_all
        return "OK"
      end

    end
  end
end