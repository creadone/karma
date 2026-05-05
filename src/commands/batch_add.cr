module Karma
  module Commands
    module BatchAdd
      def self.call(directive, cluster)
        series = directive.series
        items = directive.items.not_nil!

        cluster.pick(series.name) do |tree|
          return apply(tree, items)
        end
      end

      def self.apply(tree, items : Array(Array(UInt64)))
        preflight!(tree, items)

        total = 0_u64
        items.each do |item|
          value = item[2]
          total = checked_add(total, value)
          tree.increment(item[0], item[1], value)
        end

        Karma::Operations.record_batch_write(items.size)
        {applied: items.size, total: total}
      end

      def self.preflight!(tree, items : Array(Array(UInt64))) : Nil
        deltas = Hash(Tuple(UInt64, UInt64), UInt64).new(0_u64)

        items.each do |item|
          key = item[0]
          bucket = item[1]
          value = item[2]
          delta_key = {key, bucket}
          deltas[delta_key] = checked_add(deltas[delta_key], value)
        end

        deltas.each do |(key, bucket), delta|
          current = tree.get(key).try(&.table[bucket]?) || 0_u64
          if UInt64::MAX - current < delta
            raise Karma::Error.new("validation_error", "Counter overflow in batch item key=#{key} bucket=#{bucket}")
          end
        end
      end

      def self.checked_add(left : UInt64, right : UInt64) : UInt64
        raise Karma::Error.new("validation_error", "Batch total overflow") if UInt64::MAX - left < right

        left + right
      end
    end
  end
end
