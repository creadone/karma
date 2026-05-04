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
        tree.branches.sum { |branch| branch.size }
      end
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
      Karma::Wal.truncate
      Karma::Backup.prune(dump_dir, Karma.config.dump_retention_per_tree)
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
        Karma::Backup.dump_tree_name(file_name)
      end

      tree_groups.each do |tree_name, group|
        group.sort! do |a, b|
          Karma::Backup.dump_timestamp(a) <=> Karma::Backup.dump_timestamp(b)
        end
        dump_path = group.last
        Karma::Backup.load(cluster, dump_path, tree_name)
      end

      cluster
    end

    def self.restore_with_wal(dump_dir) : Cluster
      cluster = restore(dump_dir)
      Karma::Wal.replay(cluster, dump_dir)
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
