module Karma
  module Commands
    module DeleteBefore
      def self.call(directive, cluster)
        cluster.delete_before(directive.series_name, directive.date.not_nil!)
        Karma::Operations.record_retention
        "OK"
      end
    end
  end
end
