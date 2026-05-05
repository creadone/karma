require "counter_tree"

module Karma
  class Cluster
    alias ClusterType = Hash(String, CounterTree::Tree)
    getter trees : ClusterType

    def initialize
      @trees = ClusterType.new
    end

    def each_tree(&) : Nil
      @trees.each do |key, tree|
        yield key, tree
      end
    end

    def tree_count : Int32
      @trees.size
    end

    def key_count : Int32
      @trees.values.sum do |tree|
        tree.key_count
      end
    end

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

    def validate! : Bool
      each_tree do |name, tree|
        begin
          tree.validate!
        rescue ex
          raise Karma::Error.new("validation_error", "Tree \"#{name}\" failed validation: #{ex.message}")
        end
      end

      true
    end

    def create(name : String) : CounterTree::Tree
      find_or_create(name)
    end

    def delete(name : String) : Bool
      @trees.delete(name) ? true : false
    end

    def pick(name : String, &) : Nil
      yield find_or_create(name)
    end

    def get(name : String) : CounterTree::Tree
      @trees[name]? || raise Karma::Error.new("not_found", "Tree \"#{name}\" not found")
    end

    def dump(name : String) : Slice(UInt8)
      CounterTree.dump(@trees[name])
    end

    def load(name : String, io : Slice(UInt8)) : Bool
      @trees[name] = CounterTree.load(io)
      true
    end

    def replace(name : String, tree : CounterTree::Tree) : Bool
      @trees[name] = tree
      true
    end

    def delete_before(name : String, date : UInt64) : Bool
      get(name).delete_before(date)
    end

    def compact(name : String) : Bool
      get(name).compact!
    end

    def compact : Bool
      each_tree do |_, tree|
        tree.compact!
      end
      true
    end

    def dump_all : Nil
      dump_dir = Karma.config.dump_dir
      each_tree do |tree_name, _tree|
        dump_name = "#{Time.local.to_unix}_#{tree_name}.tree"
        dump_path = File.join(dump_dir, dump_name)
        Karma::Backup.dump(self, dump_path, tree_name)
      end
      Karma::Wal.truncate
      Karma::Backup.prune(dump_dir, Karma.config.dump_retention_per_tree)
    end

    def self.restore(dump_dir) : Cluster
      cluster = Cluster.new

      full_path = File.expand_path(dump_dir)
      pattern = File.join(full_path, "*.tree")
      dumps = Dir.glob(pattern).select do |path|
        File.file?(path)
      end
      return cluster if dumps.size == 0

      tree_groups = dumps.group_by do |file_name|
        Karma::Backup.dump_tree_name(file_name)
      end

      tree_groups.each do |tree_name, group|
        group.sort! do |a, b|
          Karma::Backup.dump_timestamp(a) <=> Karma::Backup.dump_timestamp(b)
        end
        dump_path = group.last
        Karma::Backup.load(cluster, dump_path, tree_name)
      end

      cluster
    end

    def self.restore_with_wal(dump_dir) : Cluster
      cluster = restore(dump_dir)
      Karma::Wal.replay(cluster, dump_dir)
      cluster
    end

    private def find_or_create(name : String) : CounterTree::Tree
      unless @trees.has_key?(name)
        @trees[name] = CounterTree::Tree.new
      end
      @trees[name]
    end
  end
end
