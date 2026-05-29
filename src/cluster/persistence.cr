module Karma
  class Cluster
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
      Karma::Idempotency.dump(dump_dir)
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
      Karma::Idempotency.restore(dump_dir)
      Karma::Wal.replay(cluster, dump_dir)
      cluster
    end
  end
end
