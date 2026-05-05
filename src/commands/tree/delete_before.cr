module Karma
  module Commands
    module DeleteBefore
      def self.call(directive, cluster)
        series = directive.series
        cluster.delete_before(series.name, directive.date.not_nil!)
        Karma::Operations.record_retention
        "OK"
      end
    end
  end
end
