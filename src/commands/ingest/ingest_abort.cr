module Karma
  module Commands
    module IngestAbort
      def self.call(directive, cluster)
        Karma::Ingest.abort(directive.stream_id.not_nil!)
      end
    end
  end
end
