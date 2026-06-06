require "msgpack"
require "./bucketed_counter/*"

module Karma::BucketedCounter
  def self.load(io : Slice(UInt8)) : Store
    Store.from_msgpack(io)
  end

  def self.dump(store : Store) : Slice(UInt8)
    store.to_msgpack
  end
end
