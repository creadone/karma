module Karma
  module Commands
    module Ping

      def self.call(directive, cluster)
        "pong"
      end

    end
  end
end