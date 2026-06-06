require "../spec_helper"

store = Karma::BucketedCounter::Store.new
store_bytes = Bytes[130, 172, 98, 114, 97, 110, 99, 104, 101, 115, 95, 110, 117, 109, 9, 168, 98, 114, 97, 110, 99, 104, 101, 115, 153, 128, 129, 205, 4, 210, 130, 165, 116, 97, 98, 108, 101, 128, 165, 116, 111, 116, 97, 108, 0, 129, 205, 4, 211, 130, 165, 116, 97, 98, 108, 101, 128, 165, 116, 111, 116, 97, 108, 0, 128, 128, 128, 128, 128, 128]
timestamps = [20230201, 20230202, 20230203, 20230204, 20230205]

describe Karma::BucketedCounter do
  it "should increment and return 1" do
    result = store.increment(1234)
    result.should eq(1_u64)
  end

  it "increments an explicit date by value" do
    store.reset
    store.increment(1234_u64, 20230201_u64, 5_u64).should eq(5_u64)
    store.sum(1234_u64, 20230201_u64, 20230201_u64).should eq(5_u64)
    store.sum(1234_u64).should eq(5_u64)
  end

  it "decrements an explicit date by value" do
    store.reset
    store.increment(1234_u64, 20230201_u64, 5_u64)
    store.decrement(1234_u64, 20230201_u64, 2_u64).should eq(2_u64)
    store.sum(1234_u64, 20230201_u64, 20230201_u64).should eq(3_u64)
  end

  it "sets an explicit key/date to an absolute value" do
    store.reset
    store.increment(1234_u64, 20230201_u64, 5_u64)
    store.set(1234_u64, 20230201_u64, 2_u64).should eq(2_u64)
    store.sum(1234_u64).should eq(2_u64)
    store.set(1234_u64, 20230201_u64, 0_u64).should eq(0_u64)
    store.sum(1234_u64).should eq(0_u64)
    store.compact!
    store.get(1234_u64).should be_nil
  end

  it "should reset global" do
    store.increment(1234)
    store.reset
    store.sum(1234_u64).should eq(0)
  end

  it "should decrement and return 1" do
    result = store.decrement(1234)
    result.should eq(1_u64)
  end

  it "should return sum" do
    store.reset
    5.times { store.increment(1234_u64) }
    store.sum(1234_u64).should eq(5_u64)
  end

  it "does not create counter when summing missing key" do
    store.reset
    store.sum(9876_u64).should eq(0_u64)
    store.counter?(9876_u64).should be_nil
  end

  it "gets existing counters without creating missing counters" do
    local_store = Karma::BucketedCounter::Store.new
    local_store.get(1234_u64).should be_nil
    local_store.get_or_create(1234_u64).should be_a(Karma::BucketedCounter::Counter)
    local_store.get(1234_u64).should be_a(Karma::BucketedCounter::Counter)
  end

  it "should return sum between dates" do
    store.reset
    counter = store.get_or_create(1234_u64)
    timestamps.each { |t| counter.insert(t.to_u64, 1_u64) }
    key_from = counter.table.keys[1]
    key_to = counter.table.keys[3]
    store.sum(1234_u64, key_from, key_to).should eq(3_u64)
  end

  it "should return hash between dates" do
    store.reset
    counter = store.get_or_create(1234_u64)
    timestamps.each { |t| counter.insert(t.to_u64, 1_u64) }
    key_from = counter.table.keys[1]
    key_to = counter.table.keys[3]
    result = store.find(1234_u64, key_from, key_to)
    result.should eq({20230202 => 1, 20230203 => 1, 20230204 => 1})
  end

  it "does not create counter when finding missing key" do
    store.reset
    store.find(9876_u64, 20230201_u64, 20230202_u64).should be_empty
    store.counter?(9876_u64).should be_nil
  end

  it "does not create counter when deleting missing key" do
    store.reset
    store.delete(9876_u64, 20230201_u64, 20230202_u64).should be_true
    store.counter?(9876_u64).should be_nil
  end

  it "should reset counter" do
    store.reset
    5.times { store.increment(1234_u64) }
    store.reset(1234_u64)
    store.get_or_create(1234_u64).total.should eq(0_u64)
  end

  it "should delete values between dates" do
    store.reset
    counter = store.get_or_create(1234_u64)
    timestamps.each { |t| counter.insert(t.to_u64, 1_u64) }
    key_from = counter.table.keys[1]
    key_to = counter.table.keys[3]
    store.delete(1234_u64, key_from, key_to)
    store.get_or_create(1234_u64).table.keys.size.should eq(2)
  end

  it "keeps total consistent after deleting values between dates" do
    store.reset
    counter = store.get_or_create(1234_u64)
    timestamps.each { |t| counter.insert(t.to_u64, 1_u64) }

    store.delete(1234_u64, 20230201_u64, 20230202_u64)

    store.sum(1234_u64).should eq(3_u64)
    store.sum(1234_u64).should eq(store.get_or_create(1234_u64).table.values.sum)
  end

  it "keeps total consistent after dump and load" do
    store.reset
    counter = store.get_or_create(1234_u64)
    timestamps.each { |t| counter.insert(t.to_u64, 1_u64) }
    store.delete(1234_u64, 20230201_u64, 20230202_u64)

    restored_store = Karma::BucketedCounter.load(Karma::BucketedCounter.dump(store))

    restored_store.sum(1234_u64).should eq(3_u64)
    restored_store.sum(1234_u64).should eq(restored_store.get_or_create(1234_u64).table.values.sum)
  end

  it "compacts empty counters" do
    store.reset
    store.increment(1234_u64, 20230201_u64, 1_u64)
    store.decrement(1234_u64, 20230201_u64, 1_u64)
    store.get(1234_u64).should_not be_nil
    store.compact!
    store.get(1234_u64).should be_nil
  end

  it "validates store invariants" do
    store.reset
    store.increment(1234_u64, 20230201_u64, 1_u64)
    store.valid?.should be_true
    store.validate!.should be_true
  end

  it "matches a reference hash after deterministic operation sequences" do
    local_store = Karma::BucketedCounter::Store.new
    reference = Hash(UInt64, Hash(UInt64, UInt64)).new do |hash, key|
      hash[key] = Hash(UInt64, UInt64).new(0_u64)
    end

    500.times do |index|
      key = ((index * 17) % 23).to_u64
      date = (20230201 + ((index * 7) % 11)).to_u64
      value = ((index % 5) + 1).to_u64

      case index % 4
      when 0, 1
        local_store.increment(key, date, value)
        reference[key][date] += value
      when 2
        local_store.decrement(key, date, value)
        current = reference[key][date]
        if current <= value
          reference[key].delete(date)
        else
          reference[key][date] = current - value
        end
      else
        from = 20230203_u64
        to = 20230206_u64
        local_store.delete(key, from, to)
        reference[key].keys.each do |stored_date|
          reference[key].delete(stored_date) if stored_date >= from && stored_date <= to
        end
      end
    end

    reference.each do |key, buckets|
      expected_total = buckets.values.sum(0_u64)
      local_store.sum(key).should eq(expected_total)
      local_store.find(key, 20230201_u64, 20230211_u64).should eq(buckets)
    end

    local_store.validate!.should be_true
  end

  it "should delete values between dates over all counters" do
    store.reset
    counter1 = store.get_or_create(1234_u64)
    counter2 = store.get_or_create(1235_u64)
    timestamps.each do |t|
      counter1.insert(t.to_u64, 1_u64)
      counter2.insert(t.to_u64, 1_u64)
    end

    key_from = counter1.table.keys[1]
    key_to = counter1.table.keys[3]

    store.delete(key_from, key_to)
    store.get_or_create(1234_u64).table.keys.size.should eq(2)
    store.get_or_create(1235_u64).table.keys.size.should eq(2)
  end

  it "should return hash between timestamps over all counters" do
    store.reset

    result = {
      1234 => {20230202 => 1, 20230203 => 1, 20230204 => 1},
      1235 => {20230202 => 1, 20230203 => 1, 20230204 => 1},
    }

    counter1 = store.get_or_create(1234_u64)
    counter2 = store.get_or_create(1235_u64)

    timestamps.each do |t|
      counter1.insert(t.to_u64, 1_u64)
      counter2.insert(t.to_u64, 1_u64)
    end

    key_from = counter1.table.keys[1]
    key_to = counter1.table.keys[3]

    store.find(key_from, key_to).should eq(result)
  end

  it "should dump store to msgpack" do
    store.reset
    Karma::BucketedCounter.dump(store).should eq(store_bytes)
  end

  it "should load store to msgpack" do
    restored_store = Karma::BucketedCounter.load(store_bytes)
    restored_store.class.should eq(store.class)
  end
end
