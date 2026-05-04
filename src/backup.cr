require "random/secure"

module Karma
  module Backup
    DUMP_EXTENSION = ".tree"

    def self.dump_timestamp(file_path) : Int64
      dump_metadata(file_path)[:timestamp]
    end

    def self.dump_tree_name(file_path) : String
      dump_metadata(file_path)[:tree_name]
    end

    def self.dumps(dump_dir) : Array(String)
      dump_dir = File.expand_path(dump_dir)
      pattern = File.join(dump_dir, "*.tree")

      Dir.glob(pattern)
        .select { |path| File.file?(path) }
        .sort { |a, b| dump_timestamp(a) <=> dump_timestamp(b) }
        .reverse
    end

    def self.load(cluster, file_path, tree_name)
      if File.exists?(file_path)
        File.open(file_path) do |file|
          io = IO::Memory.new(file.size.to_i)
          IO.copy(file, io)
          cluster.load(tree_name, io.to_slice)
          true
        end
      else
        raise Karma::Error.new("not_found", "Dump \"#{tree_name}\" not found")
      end
    end

    def self.dump(cluster, file_path, tree_name)
      if cluster.trees.has_key?(tree_name)
        dir_path = File.dirname(file_path)
        Dir.mkdir_p(dir_path) unless Dir.exists?(dir_path)

        temp_path = File.join(
          dir_path,
          ".#{File.basename(file_path)}.#{Process.pid}.#{Random::Secure.hex(8)}.tmp"
        )

        File.open(temp_path, "wb") do |io|
          io.write cluster.dump(tree_name)
          io.flush
          io.fsync
        end

        File.rename(temp_path, file_path)
        Karma::Log.info("backup.dump", "tree=#{tree_name} path=#{file_path}")
        true
      else
        raise Karma::Error.new("not_found", "Tree \"#{tree_name}\" not found")
      end
    ensure
      File.delete(temp_path) if temp_path && File.exists?(temp_path)
    end

    def self.prune(dump_dir, retain_per_tree : Int32) : Int32
      return 0 if retain_per_tree <= 0

      removed = 0
      dumps(dump_dir)
        .group_by { |path| dump_tree_name(path) }
        .each_value do |paths|
          paths.sort! { |a, b| dump_timestamp(b) <=> dump_timestamp(a) }
          paths.skip(retain_per_tree).each do |path|
            File.delete(path)
            removed += 1
          end
        end
      Karma::Log.info("backup.prune", "removed=#{removed}") if removed > 0
      removed
    end

    def self.verify(dump_dir)
      cluster = Cluster.restore_with_wal(dump_dir)
      {
        status:     "ok",
        dump_count: dumps(dump_dir).size,
        trees:      cluster.tree_count,
        keys:       cluster.key_count,
      }
    end

    private def self.dump_metadata(file_path) : NamedTuple(timestamp: Int64, tree_name: String)
      basename = File.basename(file_path, DUMP_EXTENSION)
      separator = basename.index("_")
      raise Karma::Error.new("validation_error", "Invalid dump file name \"#{file_path}\"") if separator.nil?

      timestamp = basename[0, separator].to_i64
      tree_name = basename[(separator + 1)..-1]
      raise Karma::Error.new("validation_error", "Invalid dump file name \"#{file_path}\"") if tree_name.empty?

      {timestamp: timestamp, tree_name: tree_name}
    end
  end
end
