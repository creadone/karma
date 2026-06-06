module Karma
  module Commands
    module BatchSet
      def self.call(directive, cluster)
        items = directive.items.not_nil!
        return {applied: 0} if items.empty?

        series_name = directive.series_name
        if cluster.trees[series_name]?.nil?
          preflight!(Karma::BucketedCounter::Store.new, items)
        end

        cluster.pick(series_name) do |tree|
          result = apply(tree, items)
          return {applied: result[:applied]}
        end
      end

      def self.apply(tree, items : Array(Array(UInt64)))
        preflight!(tree, items)

        total = 0_u64
        items.each do |item|
          value = item[2]
          total = Commands::BatchAdd.checked_add(total, value)
          tree.set(item[0], item[1], value)
        end

        Karma::Operations.record_batch_write(items.size)
        {applied: items.size, total: total}
      end

      def self.preflight!(tree, items : Array(Array(UInt64))) : Nil
        final_values = Hash(Tuple(UInt64, UInt64), UInt64).new
        items.each do |item|
          final_values[{item[0], item[1]}] = item[2]
        end

        new_total = tree.total_sum.to_u128
        final_values.each do |(key, bucket), value|
          current = tree.get(key).try(&.table[bucket]?) || 0_u64
          if value >= current
            new_total += (value - current).to_u128
          else
            new_total -= (current - value).to_u128
          end

          raise Karma::Error.new("validation_error", "Counter overflow in batch item key=#{key} bucket=#{bucket}") if new_total > UInt64::MAX.to_u128
        end
      end
    end
  end
end
