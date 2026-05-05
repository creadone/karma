require "./spec_helper"

counter = CounterTree::Counter.new
timestamps = [20230201, 20230202, 20230203, 20230204, 20230205]

describe CounterTree do
  it "should return 1" do
    counter.reset
    result = counter.increment
    result.should eq(1_u64)
    counter.table.has_key?(Time.utc.to_s("%Y%m%d").to_u64).should be_true
  end

  it "should return 0" do
    counter.reset
    result = counter.decrement
    result.should eq(1_u64)
  end

  it "should return inserted value" do
    result = counter.insert(20230201, 5_u64)
    result.should eq(5_u64)
  end

  it "increments an explicit date by value" do
    counter.reset
    counter.increment(20230201_u64, 5_u64).should eq(5_u64)
    counter.table[20230201_u64].should eq(5_u64)
    counter.sum.should eq(5_u64)
  end

  it "decrements an explicit date by value" do
    counter.reset
    counter.increment(20230201_u64, 5_u64)
    counter.decrement(20230201_u64, 2_u64).should eq(2_u64)
    counter.table[20230201_u64].should eq(3_u64)
    counter.sum.should eq(3_u64)
  end

  it "sets an explicit date to an absolute value" do
    counter.reset
    counter.increment(20230201_u64, 5_u64)
    counter.set(20230201_u64, 3_u64).should eq(3_u64)
    counter.table[20230201_u64].should eq(3_u64)
    counter.sum.should eq(3_u64)

    counter.set(20230201_u64, 0_u64).should eq(0_u64)
    counter.table.has_key?(20230201_u64).should be_false
    counter.sum.should eq(0_u64)
  end

  it "removes zero buckets after decrement" do
    counter.reset
    counter.insert(20230201_u64, 5_u64)
    counter.remove(20230201_u64, 5_u64)
    counter.table.has_key?(20230201_u64).should be_false
    counter.sum.should eq(0_u64)
  end

  it "should return removed value" do
    timestamp = Time.local.to_unix_ms.to_u64
    result = counter.insert(timestamp, 5_u64)
    result.should eq(5_u64)
  end

  it "should reset counter" do
    empty_hash = Hash(UInt64, UInt64).new
    counter.increment
    counter.reset
    counter.table.should eq(empty_hash)
  end

  it "should return hash between dates" do
    timestamps.each { |t| counter.insert(t.to_u64, 1_u64) }
    result = counter.find(20230201, 20230203)
    result.should eq({20230201 => 1, 20230202 => 1, 20230203 => 1})
  end

  it "should return true after delete_each" do
    counter.reset
    timestamps.each { |t| counter.insert(t.to_u64, 1_u64) }
    result = counter.delete(20230201, 20230202)
    counter.table.should eq({20230203 => 1, 20230204 => 1, 20230205 => 1})
  end

  it "keeps total consistent after delete_each" do
    counter.reset
    timestamps.each { |t| counter.insert(t.to_u64, 1_u64) }
    counter.delete(20230201, 20230202)
    counter.sum.should eq(counter.table.values.sum)
  end

  it "keeps total unchanged when removing missing timestamp" do
    counter.reset
    counter.insert(20230201, 5_u64)
    counter.remove(20230202, 1_u64)
    counter.sum.should eq(5_u64)
    counter.sum.should eq(counter.table.values.sum)
  end

  it "deletes buckets before a date" do
    counter.reset
    timestamps.each { |t| counter.insert(t.to_u64, 1_u64) }
    counter.delete_before(20230203_u64)
    counter.table.should eq({20230203_u64 => 1_u64, 20230204_u64 => 1_u64, 20230205_u64 => 1_u64})
  end

  it "validates consistent counters" do
    counter.reset
    counter.insert(20230201_u64, 5_u64)
    counter.valid?.should be_true
    counter.validate!.should be_true
  end

  it "raises on UInt64 overflow" do
    counter.reset
    counter.insert(20230201_u64, UInt64::MAX)
    expect_raises(OverflowError) do
      counter.insert(20230201_u64, 1_u64)
    end
  end

  it "should return sum" do
    counter.reset
    timestamps.each { |t| counter.insert(t.to_u64, 5_u64) }
    counter.sum.should eq(5 * timestamps.size)
  end

  it "should return sum between timestamps" do
    counter.reset
    timestamps.each { |t| counter.insert(t.to_u64, 5_u64) }
    counter.sum(20230201, 20230203).should eq(15)
  end
end
