module Karma
  module Commands
    module BatchSum
      def self.call(directive, cluster)
        tree = cluster.get(directive.series_name)
        keys = directive.keys.not_nil!
        range = directive.bucket_range?

        response = keys.map do |key|
          value = range ? tree.sum(key, range.from.value, range.to.value) : tree.sum(key)

          {key: key, value: value}
        end
        Karma::Operations.record_batch_read(keys.size)
        response
      end
    end
  end
end
