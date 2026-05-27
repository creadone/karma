module Karma
  module Commands
    module BatchDeleteRange
      def self.call(directive, cluster)
        tree = cluster.get(directive.series_name)
        keys = directive.keys.not_nil!
        range = directive.bucket_range
        deleted = 0
        missing = 0

        keys.each do |key|
          counter = tree.get(key)
          unless counter && !counter.table.empty?
            missing += 1
            next
          end

          next unless counter.table.any? { |bucket, _| bucket >= range.from.value && bucket <= range.to.value }

          counter.delete(range.from.value, range.to.value)
          deleted += 1
        end

        Karma::Operations.record_batch_write(keys.size)
        {deleted: deleted, missing: missing}
      end
    end
  end
end
