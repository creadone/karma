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
      with_counter(key) do |c|
        return c.increment
      end
    end

    def decrement(key : UInt64) : UInt64
      with_counter(key) do |c|
        return c.decrement
      end
    end

    def sum(key : UInt64) : UInt64
      counter?(key).try(&.sum) || 0_u64
    end

    def sum(key : UInt64, time_from : UInt64, time_to : UInt64) : UInt64
      counter?(key).try(&.sum(time_from, time_to)) || 0_u64
    end

    def find(key : UInt64, time_from : UInt64, time_to : UInt64) : Hash(UInt64, UInt64)
      counter?(key).try(&.find(time_from, time_to)) || Hash(UInt64, UInt64).new
    end

    def find(time_from : UInt64, time_to : UInt64) : Hash(UInt64, Hash(UInt64, UInt64))
      store = Hash(UInt64, Hash(UInt64, UInt64)).new
      each_counter do |key, counter|
        store[key] = counter.find(time_from, time_to)
      end
      store
    end

    def delete(key : UInt64, time_from : UInt64, time_to : UInt64) : Bool
      with_counter(key) do |c|
        return c.delete(time_from, time_to)
      end
    end

    def delete(time_from : UInt64, time_to : UInt64) : Bool
      each_counter do |key, counter|
        counter.delete(time_from, time_to)
      end
      true
    end

    def reset(key : UInt64) : Bool
      with_counter(key) do |c|
        return c.reset
      end
    end

    def reset : Bool
      each_counter do |key, counter|
        counter.reset
      end
      true
    end

    def pick(key : UInt64) : Counter
      with_counter(key) do |c|
        return c
      end
    end

    def counter?(key : UInt64) : Counter?
      index = branch_index(key)
      @branches[index][key]?
    end

    private def each_counter(&) : Nil
      @branches.each do |branch|
        branch.each do |key, counter|
          yield key, counter
        end
      end
    end

    private def with_counter(key : UInt64, &) : Nil
      index = branch_index(key)
      unless @branches[index][key]?
        @branches[index][key] = Counter.new
      end
      yield @branches[index][key]
    end

    private def branch_index(key : UInt64) : UInt64
      (key % @branches_num).to_u64
    end
  end
end
