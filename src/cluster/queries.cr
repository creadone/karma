module Karma
  class Cluster
    def tree_info(name : String)
      tree = get(name)
      deadline = QueryDeadline.new
      key_count = 0
      bucket_count = 0
      total = 0_u64

      tree.each_counter do |_, counter|
        deadline.check!
        key_count += 1
        bucket_count += counter.table.size
        total += counter.sum
      end

      {
        tree:         name,
        key_count:    key_count,
        bucket_count: bucket_count,
        total:        total,
        branches:     tree.branches_num,
      }
    end

    def tree_keys(name : String, limit : Int32, cursor : UInt64?)
      tree = get(name)
      deadline = QueryDeadline.new
      keys = [] of UInt64
      tree.each_counter do |key, _|
        deadline.check!
        next if cursor && key <= cursor
        keys << key
      end

      deadline.check!
      keys.sort!
      page = keys.first(limit)
      has_more = keys.size > page.size
      {
        tree:        name,
        limit:       limit,
        cursor:      cursor,
        next_cursor: has_more && page.size > 0 ? page.last : nil,
        keys:        page.map { |key|
          deadline.check!
          {key: key, total: tree.sum(key)}
        },
      }
    end

    def tree_summary(name : String, range : Karma::TimeSeries::BucketRange?)
      tree = get(name)
      deadline = QueryDeadline.new
      if range
        active_keys = 0
        bucket_count = 0
        total = 0_u64
        tree.each_counter do |_, counter|
          deadline.check!
          counter_total = counter.sum(range.from.value, range.to.value)
          if counter_total > 0_u64
            active_keys += 1
            total += counter_total
            bucket_count += counter.find(range.from.value, range.to.value).size
          end
        end

        {
          tree:         name,
          range_from:   range.from.value,
          range_to:     range.to.value,
          total:        total,
          active_keys:  active_keys,
          bucket_count: bucket_count,
        }
      else
        active_keys = 0
        bucket_count = 0
        total = 0_u64
        tree.each_counter do |_, counter|
          deadline.check!
          active_keys += 1
          bucket_count += counter.table.size
          total += counter.sum
        end

        {
          tree:         name,
          total:        total,
          active_keys:  active_keys,
          bucket_count: bucket_count,
        }
      end
    end

    def tree_top(name : String, limit : Int32, range : Karma::TimeSeries::BucketRange?)
      tree = get(name)
      deadline = QueryDeadline.new
      items = [] of NamedTuple(key: UInt64, value: UInt64)
      tree.each_counter do |key, counter|
        deadline.check!
        value = range ? counter.sum(range.from.value, range.to.value) : counter.sum
        items << {key: key, value: value} if value > 0_u64
      end

      deadline.check!
      items.sort! do |left, right|
        by_value = right[:value] <=> left[:value]
        by_value == 0 ? left[:key] <=> right[:key] : by_value
      end

      {
        tree:  name,
        limit: limit,
        items: items.first(limit),
      }
    end

    def tree_series(name : String, range : Karma::TimeSeries::BucketRange)
      tree = get(name)
      deadline = QueryDeadline.new
      store = Hash(UInt64, Hash(UInt64, UInt64)).new
      tree.each_counter do |key, counter|
        deadline.check!
        store[key] = counter.find(range.from.value, range.to.value)
      end
      store
    end
  end
end
