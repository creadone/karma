module CounterTree
  class Tree
    include MessagePack::Serializable

    getter branches = [] of Hash(UInt64, CounterTree::Counter)
    getter branches_num : UInt32

    def initialize(@branches_num = 9)
      @branches = Array.new(@branches_num) do
        Hash(UInt64, CounterTree::Counter).new
      end
    end

    def increment(key : UInt64) : UInt64
      get_or_create(key).increment
    end

    def increment(key : UInt64, date : UInt64, value : UInt64 = 1_u64) : UInt64
      get_or_create(key).increment(date, value)
    end

    def decrement(key : UInt64) : UInt64
      get_or_create(key).decrement
    end

    def decrement(key : UInt64, date : UInt64, value : UInt64 = 1_u64) : UInt64
      get_or_create(key).decrement(date, value)
    end

    def sum(key : UInt64) : UInt64
      get(key).try(&.sum) || 0_u64
    end

    def sum(key : UInt64, time_from : UInt64, time_to : UInt64) : UInt64
      get(key).try(&.sum(time_from, time_to)) || 0_u64
    end

    def find(key : UInt64, time_from : UInt64, time_to : UInt64) : Hash(UInt64, UInt64)
      get(key).try(&.find(time_from, time_to)) || Hash(UInt64, UInt64).new
    end

    def find(time_from : UInt64, time_to : UInt64) : Hash(UInt64, Hash(UInt64, UInt64))
      store = Hash(UInt64, Hash(UInt64, UInt64)).new
      each_counter do |key, counter|
        store[key] = counter.find(time_from, time_to)
      end
      store
    end

    def each_counter(&) : Nil
      @branches.each do |branch|
        branch.each do |key, counter|
          yield key, counter
        end
      end
    end

    def key_count : Int32
      @branches.sum { |branch| branch.size }
    end

    def bucket_count : Int32
      total = 0
      each_counter do |_, counter|
        total += counter.table.size
      end
      total
    end

    def total_sum : UInt64
      total = 0_u64
      each_counter do |_, counter|
        total += counter.sum
      end
      total
    end

    def range_sum(time_from : UInt64, time_to : UInt64) : UInt64
      total = 0_u64
      each_counter do |_, counter|
        total += counter.sum(time_from, time_to)
      end
      total
    end

    def delete(key : UInt64, time_from : UInt64, time_to : UInt64) : Bool
      get(key).try(&.delete(time_from, time_to))
      true
    end

    def delete(time_from : UInt64, time_to : UInt64) : Bool
      each_counter do |key, counter|
        counter.delete(time_from, time_to)
      end
      true
    end

    def reset(key : UInt64) : Bool
      get(key).try(&.reset)
      true
    end

    def reset : Bool
      each_counter do |key, counter|
        counter.reset
      end
      true
    end

    @[Deprecated("Use get_or_create(key) instead.")]
    def pick(key : UInt64) : Counter
      get_or_create(key)
    end

    def get(key : UInt64) : Counter?
      index = branch_index(key)
      @branches[index][key]?
    end

    def get_or_create(key : UInt64) : Counter
      index = branch_index(key)
      @branches[index][key] ||= Counter.new
    end

    def counter?(key : UInt64) : Counter?
      get(key)
    end

    def delete_before(date : UInt64) : Bool
      each_counter do |_, counter|
        counter.delete_before(date)
      end
      compact!
    end

    def keep_from(date : UInt64) : Bool
      delete_before(date)
    end

    def compact! : Bool
      @branches.each do |branch|
        keys_to_delete = [] of UInt64
        branch.each do |key, counter|
          counter.compact!
          keys_to_delete << key if counter.sum == 0_u64
        end
        keys_to_delete.each { |key| branch.delete(key) }
      end
      true
    end

    def valid? : Bool
      validate!
      true
    rescue
      false
    end

    def validate! : Bool
      raise ArgumentError.new("tree branch count mismatch") unless @branches.size == @branches_num

      each_counter do |_, counter|
        counter.validate!
      end

      true
    end

    private def branch_index(key : UInt64) : UInt64
      (key % @branches_num).to_u64
    end
  end
end
