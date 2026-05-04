require "msgpack"
require "./lib/*"

module CounterTree
  VERSION = "1.0.1"

  def self.load(io : Slice(UInt8)) : Tree
    Tree.from_msgpack(io)
  end

  def self.dump(tree : Tree) : Slice(UInt8)
    tree.to_msgpack
  end
end