require "./spec_helper"

tree = CounterTree::Tree.new
tree_bytes = Bytes[130, 172, 98, 114, 97, 110, 99, 104, 101, 115, 95, 110, 117, 109, 9, 168, 98, 114, 97, 110, 99, 104, 101, 115, 153, 128, 129, 205, 4, 210, 130, 165, 116, 97, 98, 108, 101, 128, 165, 116, 111, 116, 97, 108, 0, 129, 205, 4, 211, 130, 165, 116, 97, 98, 108, 101, 128, 165, 116, 111, 116, 97, 108, 0, 128, 128, 128, 128, 128, 128]
timestamps = [20230201, 20230202, 20230203, 20230204, 20230205]

describe CounterTree do
  it "should increment and return 1" do
    result = tree.increment(1234)
    result.should eq(1_u64)
  end

  it "increments an explicit date by value" do
    tree.reset
    tree.increment(1234_u64, 20230201_u64, 5_u64).should eq(5_u64)
    tree.sum(1234_u64, 20230201_u64, 20230201_u64).should eq(5_u64)
    tree.sum(1234_u64).should eq(5_u64)
  end

  it "decrements an explicit date by value" do
    tree.reset
    tree.increment(1234_u64, 20230201_u64, 5_u64)
    tree.decrement(1234_u64, 20230201_u64, 2_u64).should eq(2_u64)
    tree.sum(1234_u64, 20230201_u64, 20230201_u64).should eq(3_u64)
  end

  it "sets an explicit key/date to an absolute value" do
    tree.reset
    tree.increment(1234_u64, 20230201_u64, 5_u64)
    tree.set(1234_u64, 20230201_u64, 2_u64).should eq(2_u64)
    tree.sum(1234_u64).should eq(2_u64)
    tree.set(1234_u64, 20230201_u64, 0_u64).should eq(0_u64)
    tree.sum(1234_u64).should eq(0_u64)
    tree.compact!
    tree.get(1234_u64).should be_nil
  end

  it "should reset global" do
    tree.increment(1234)
    tree.reset
    tree.sum(1234_u64).should eq(0)
  end

  it "should decrement and return 1" do
    result = tree.decrement(1234)
    result.should eq(1_u64)
  end

  it "should return sum" do
    tree.reset
    5.times { tree.increment(1234_u64) }
    tree.sum(1234_u64).should eq(5_u64)
  end

  it "does not create counter when summing missing key" do
    tree.reset
    tree.sum(9876_u64).should eq(0_u64)
    tree.counter?(9876_u64).should be_nil
  end

  it "gets existing counters without creating missing counters" do
    local_tree = CounterTree::Tree.new
    local_tree.get(1234_u64).should be_nil
    local_tree.get_or_create(1234_u64).should be_a(CounterTree::Counter)
    local_tree.get(1234_u64).should be_a(CounterTree::Counter)
  end

  it "should return sum between dates" do
    tree.reset
    counter = tree.pick(1234_u64)
    timestamps.each { |t| counter.insert(t.to_u64, 1_u64) }
    key_from = counter.table.keys[1]
    key_to = counter.table.keys[3]
    tree.sum(1234_u64, key_from, key_to).should eq(3_u64)
  end

  it "should return hash between dates" do
    tree.reset
    counter = tree.pick(1234_u64)
    timestamps.each { |t| counter.insert(t.to_u64, 1_u64) }
    key_from = counter.table.keys[1]
    key_to = counter.table.keys.[3]
    result = tree.find(1234_u64, key_from, key_to)
    result.should eq({20230202 => 1, 20230203 => 1, 20230204 => 1})
  end

  it "does not create counter when finding missing key" do
    tree.reset
    tree.find(9876_u64, 20230201_u64, 20230202_u64).should be_empty
    tree.counter?(9876_u64).should be_nil
  end

  it "does not create counter when deleting missing key" do
    tree.reset
    tree.delete(9876_u64, 20230201_u64, 20230202_u64).should be_true
    tree.counter?(9876_u64).should be_nil
  end

  it "should reset counter" do
    tree.reset
    5.times { tree.increment(1234_u64) }
    tree.reset(1234_u64)
    tree.pick(1234_u64).total.should eq(0_u64)
  end

  it "should delete values between dates" do
    tree.reset
    counter = tree.pick(1234_u64)
    timestamps.each { |t| counter.insert(t.to_u64, 1_u64) }
    key_from = counter.table.keys[1]
    key_to = counter.table.keys[3]
    tree.delete(1234_u64, key_from, key_to)
    tree.pick(1234_u64).table.keys.size.should eq(2)
  end

  it "keeps total consistent after deleting values between dates" do
    tree.reset
    counter = tree.pick(1234_u64)
    timestamps.each { |t| counter.insert(t.to_u64, 1_u64) }

    tree.delete(1234_u64, 20230201_u64, 20230202_u64)

    tree.sum(1234_u64).should eq(3_u64)
    tree.sum(1234_u64).should eq(tree.pick(1234_u64).table.values.sum)
  end

  it "keeps total consistent after dump and load" do
    tree.reset
    counter = tree.pick(1234_u64)
    timestamps.each { |t| counter.insert(t.to_u64, 1_u64) }
    tree.delete(1234_u64, 20230201_u64, 20230202_u64)

    restored_tree = CounterTree.load(CounterTree.dump(tree))

    restored_tree.sum(1234_u64).should eq(3_u64)
    restored_tree.sum(1234_u64).should eq(restored_tree.pick(1234_u64).table.values.sum)
  end

  it "compacts empty counters" do
    tree.reset
    tree.increment(1234_u64, 20230201_u64, 1_u64)
    tree.decrement(1234_u64, 20230201_u64, 1_u64)
    tree.get(1234_u64).should_not be_nil
    tree.compact!
    tree.get(1234_u64).should be_nil
  end

  it "validates tree invariants" do
    tree.reset
    tree.increment(1234_u64, 20230201_u64, 1_u64)
    tree.valid?.should be_true
    tree.validate!.should be_true
  end

  it "matches a reference hash after deterministic operation sequences" do
    local_tree = CounterTree::Tree.new
    reference = Hash(UInt64, Hash(UInt64, UInt64)).new do |hash, key|
      hash[key] = Hash(UInt64, UInt64).new(0_u64)
    end

    500.times do |index|
      key = ((index * 17) % 23).to_u64
      date = (20230201 + ((index * 7) % 11)).to_u64
      value = ((index % 5) + 1).to_u64

      case index % 4
      when 0, 1
        local_tree.increment(key, date, value)
        reference[key][date] += value
      when 2
        local_tree.decrement(key, date, value)
        current = reference[key][date]
        if current <= value
          reference[key].delete(date)
        else
          reference[key][date] = current - value
        end
      else
        from = 20230203_u64
        to = 20230206_u64
        local_tree.delete(key, from, to)
        reference[key].keys.each do |stored_date|
          reference[key].delete(stored_date) if stored_date >= from && stored_date <= to
        end
      end
    end

    reference.each do |key, buckets|
      expected_total = buckets.values.sum(0_u64)
      local_tree.sum(key).should eq(expected_total)
      local_tree.find(key, 20230201_u64, 20230211_u64).should eq(buckets)
    end

    local_tree.validate!.should be_true
  end

  it "should delete values between dates over all counters" do
    tree.reset
    counter1 = tree.pick(1234_u64)
    counter2 = tree.pick(1235_u64)
    timestamps.each do |t|
      counter1.insert(t.to_u64, 1_u64)
      counter2.insert(t.to_u64, 1_u64)
    end

    key_from = counter1.table.keys[1]
    key_to = counter1.table.keys[3]

    tree.delete(key_from, key_to)
    tree.pick(1234_u64).table.keys.size.should eq(2)
    tree.pick(1235_u64).table.keys.size.should eq(2)
  end

  it "should return hash between timestamps over all counters" do
    tree.reset

    result = {
      1234 => {20230202 => 1, 20230203 => 1, 20230204 => 1},
      1235 => {20230202 => 1, 20230203 => 1, 20230204 => 1},
    }

    counter1 = tree.pick(1234_u64)
    counter2 = tree.pick(1235_u64)

    timestamps.each do |t|
      counter1.insert(t.to_u64, 1_u64)
      counter2.insert(t.to_u64, 1_u64)
    end

    key_from = counter1.table.keys[1]
    key_to = counter1.table.keys[3]

    tree.find(key_from, key_to).should eq(result)
  end

  it "should dump tree to msgpack" do
    tree.reset
    CounterTree.dump(tree).should eq(tree_bytes)
  end

  it "should load tree to msgpack" do
    tree1 = CounterTree.load(tree_bytes)
    tree1.class.should eq(tree.class)
  end
end
