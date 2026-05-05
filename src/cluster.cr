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

    private def find_or_create(name : String) : CounterTree::Tree
      unless @trees.has_key?(name)
        @trees[name] = CounterTree::Tree.new
      end
      @trees[name]
    end
  end
end

require "./cluster/queries"
require "./cluster/persistence"
