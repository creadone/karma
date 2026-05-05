module Karma
  module Commands
    module Verify
      def self.call(directive, cluster)
        Karma::Operations.verify_restore
      end
    end
  end
end
