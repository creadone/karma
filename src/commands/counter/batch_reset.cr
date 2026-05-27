module Karma
  module Commands
    module BatchReset
      def self.call(directive, cluster)
        tree = cluster.get(directive.series_name)
        keys = directive.keys.not_nil!
        reset = 0
        missing = 0

        keys.each do |key|
          counter = tree.get(key)
          if counter && !counter.table.empty?
            counter.reset
            reset += 1
          else
            missing += 1
          end
        end

        Karma::Operations.record_batch_write(keys.size)
        {reset: reset, missing: missing}
      end
    end
  end
end
