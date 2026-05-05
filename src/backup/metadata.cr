require "json"

module Karma
  module Backup
    struct SnapshotMetadata
      include JSON::Serializable

      getter tree : String
      getter file : String
      getter timestamp : Int64
      getter last_lsn : UInt64
      getter bytes : Int64

      def initialize(@tree : String, @file : String, @timestamp : Int64, @last_lsn : UInt64, @bytes : Int64)
      end

      def to_response
        {
          tree:          tree,
          file:          file,
          timestamp:     timestamp,
          bytes:         bytes,
          last_lsn:      last_lsn,
          metadata_file: File.basename(Karma::Backup.metadata_path(file)),
        }
      end
    end

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

    def self.metadata_path(file_path) : String
      "#{file_path}#{METADATA_EXTENSION}"
    end

    def self.snapshot_metadata(file_path) : SnapshotMetadata
      metadata_path = metadata_path(file_path)
      return SnapshotMetadata.from_json(File.read(metadata_path)) if File.exists?(metadata_path)

      SnapshotMetadata.new(
        dump_tree_name(file_path),
        File.basename(file_path),
        dump_timestamp(file_path),
        0_u64,
        File.exists?(file_path) ? File.size(file_path) : 0_i64
      )
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
