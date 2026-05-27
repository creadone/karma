module Karma
  module Commands
    module MultiSum
      def self.call(directive, cluster)
        items = directive.multi_sum_items.not_nil!
        range = directive.bucket_range?

        response = items.map do |item|
          tree = cluster.get(item.series)
          value = range ? tree.sum(item.key, range.from.value, range.to.value) : tree.sum(item.key)

          {series: item.series, key: item.key, value: value}
        end

        Karma::Operations.record_batch_read(items.size)
        response
      end
    end
  end
end
