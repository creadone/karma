module Karma
  module Commands
    module RecoveryCheckpoint
      def self.call(directive, cluster)
        Karma::Recovery.checkpoint(
          source: directive.source.not_nil!,
          offset: directive.source_offset,
          event_id: directive.event_id
        ).to_response
      end
    end
  end
end
