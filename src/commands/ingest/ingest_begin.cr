module Karma
  module Commands
    module IngestBegin
      def self.call(directive, cluster)
        Karma::Ingest.begin_stream(
          directive.stream_id.not_nil!,
          directive.mode.not_nil!,
          directive.granularity
        )
      end
    end
  end
end
