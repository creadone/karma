require "counter_tree"

module Karma
  class Cluster

    alias ClusterType = Hash(String, CounterTree::Tree)
    getter trees : ClusterType

    def initialize
      @trees = ClusterType.new
    end

    def each_tree : Nil
      @trees.each do |key, tree|
        yield key, tree
      end
    end

    def create(name : String) : CounterTree::Tree
      find_or_create(name)
    end

    def delete(name : String) : Bool
      @trees.delete(name) ? true : false
    end

    def pick(name : String) : Nil
      yield find_or_create(name)
    end

    def dump(name : String) : Slice(UInt8)
      CounterTree.dump(@trees[name])
    end

    def load(name : String, io : Slice(UInt8)) : Bool
      @trees[name] = CounterTree.load(io)
      true
    end

    def dump_all : Nil
      dump_dir = Karma.config.dump_dir
      each_tree do |tree_name, _tree|
        dump_name = "#{Time.local.to_unix}_#{tree_name}.tree"
        dump_path = File.join(dump_dir, dump_name)
        Karma::Backup.dump(self, dump_path, tree_name)
      end
    end

    def self.restore(dump_dir) : Cluster
      cluster = Cluster.new

      full_path = File.expand_path(dump_dir)
      pattern = File.join(full_path, "*.tree")
      dumps = Dir.glob(pattern).select do |path|
        File.file?(path)
      end
      return cluster if dumps.size == 0

      tree_groups = dumps.group_by do |file_name|
        File.basename(file_name.split("_").last, ".tree")
      end

      tree_groups.each do |tree_name, group|
        group.sort! do |a, b|
          a.split("_").first.to_i32 <=> b.split("_").first.to_i32
        end
        dump_path = group.last
        Karma::Backup.load(cluster, dump_path, tree_name)
      end

      cluster
    end

    private def find_or_create(name : String) : CounterTree::Tree
      unless @trees.has_key?(name)
        @trees[name] = CounterTree::Tree.new
      end
      @trees[name]
    end

  end
end