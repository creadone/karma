module Karma
  module Commands
    module DumpAll
      def self.call(directive, cluster)
        cluster.dump_all
        "OK"
      end
    end
  end
end
