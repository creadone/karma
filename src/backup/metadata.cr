module Karma
  module Backup
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
