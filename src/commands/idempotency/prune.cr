module Karma
  module Commands
    module IdempotencyPrune
      def self.call(directive, cluster)
        Karma::Idempotency.prune(
          directive.before_unix.not_nil!,
          directive.limit
        )
      end
    end
  end
end
