require "./spec_helper"

counter = CounterTree::Counter.new
timestamps = [20230201, 20230202, 20230203, 20230204, 20230205]

describe CounterTree do
  it "should return 1" do
    result = counter.increment
    result.should eq(1_u64)
  end

  it "should return 0" do
    result = counter.decrement
    result.should eq(1_u64)
  end

  it "should return inserted value" do
    result = counter.insert(20230201, 5_u64)
    result.should eq(5_u64)
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
