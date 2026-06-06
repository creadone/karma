module Karma::BucketedCounter
  class Counter
    include MessagePack::Serializable

    getter table : Hash(UInt64, UInt64)
    getter total : UInt64

    def initialize
      @table = Hash(UInt64, UInt64).new
      @total = 0_u64
    end

    def increment : UInt64
      increment(timestamp)
    end

    def increment(date : UInt64, value : UInt64 = 1_u64) : UInt64
      insert(date, value)
    end

    def decrement : UInt64
      decrement(timestamp)
    end

    def decrement(date : UInt64, value : UInt64 = 1_u64) : UInt64
      remove(date, value)
    end

    def set(key : UInt64, value : UInt64) : UInt64
      current_value = @table[key]? || 0_u64

      if value == 0_u64
        @table.delete(key)
        decrement_total(current_value)
      elsif current_value == 0_u64
        @table[key] = value
        increment_total(value)
      elsif value > current_value
        @table[key] = value
        increment_total(value - current_value)
      elsif value < current_value
        @table[key] = value
        decrement_total(current_value - value)
      end

      value
    end

    def insert(key : UInt64, value : UInt64) : UInt64
      return value if value == 0_u64

      if @table.has_key?(key)
        @table[key] = checked_add(@table[key], value)
      else
        @table[key] = value
      end
      increment_total(value)
      value
    end

    def remove(key : UInt64, value : UInt64) : UInt64
      return value if value == 0_u64

      if current_value = @table[key]?
        removed_value = current_value >= value ? value : current_value

        if current_value >= value
          new_value = current_value - value
          if new_value == 0_u64
            @table.delete(key)
          else
            @table[key] = new_value
          end
        else
          @table.delete(key)
        end

        decrement_total(removed_value)
      end

      value
    end

    def find(time_from : UInt64, time_to : UInt64) : Hash(UInt64, UInt64)
      @table.select do |key, _|
        key >= time_from && key <= time_to
      end
    end

    def delete(time_from : UInt64, time_to : UInt64) : Bool
      removed_total = 0_u64
      keys_to_delete = [] of UInt64

      @table.each do |key, val|
        if key >= time_from && key <= time_to
          keys_to_delete << key
          removed_total = checked_add(removed_total, val)
        end
      end

      keys_to_delete.each { |key| @table.delete(key) }
      decrement_total(removed_total)

      true
    end

    def delete_before(date : UInt64) : Bool
      delete(0_u64, date - 1_u64) unless date == 0_u64
      true
    end

    def keep_from(date : UInt64) : Bool
      delete_before(date)
    end

    def compact! : Bool
      keys_to_delete = [] of UInt64
      @table.each do |key, value|
        keys_to_delete << key if value == 0_u64
      end
      keys_to_delete.each { |key| @table.delete(key) }
      @total = @table.values.sum(0_u64)
      true
    end

    def valid? : Bool
      validate!
      true
    rescue
      false
    end

    def validate! : Bool
      expected_total = @table.values.sum(0_u64)
      raise ArgumentError.new("counter total mismatch") unless @total == expected_total
      raise ArgumentError.new("counter contains zero bucket") if @table.any? { |_, value| value == 0_u64 }

      true
    end

    def sum : UInt64
      @total
    end

    def sum(time_from : UInt64, time_to : UInt64) : UInt64
      find(time_from, time_to).values.sum
    end

    def reset : Bool
      @table = {} of UInt64 => UInt64
      @total = 0_u64
      true
    end

    private def increment_total(value : UInt64) : UInt64
      @total = checked_add(@total, value)
    end

    private def decrement_total(value : UInt64) : UInt64
      if @total <= value
        @total = 0_u64
      else
        @total = @total - value
      end
    end

    private def timestamp : UInt64
      Time.utc.to_s("%Y%m%d").to_u64
    end

    private def checked_add(left : UInt64, right : UInt64) : UInt64
      raise OverflowError.new("counter overflow") if UInt64::MAX - left < right

      left + right
    end
  end
end
