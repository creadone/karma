module Karma
  module Commands
    module IngestCommit
      def self.call(directive, cluster)
        Karma::Ingest.commit(directive.stream_id.not_nil!)
      end
    end
  end
end
