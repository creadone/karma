module Karma
  module Wal
    FILE_NAME         = "karma.wal"
    LSN_FILE_NAME     = "karma.wal.lsn"
    SEGMENT_EXTENSION = ".segment"
    INDEX_EXTENSION   = ".idx"
    @@paths_cache_mutex = Mutex.new
    @@paths_cache_dir : String?
    @@paths_cache_mtime : Time?
    @@paths_cache_paths = [] of String

    def self.enabled? : Bool
      Karma.config.wal
    end

    def self.fsync? : Bool
      Karma.config.wal_fsync
    end

    def self.path(dump_dir = Karma.config.dump_dir) : String
      File.join(File.expand_path(dump_dir), FILE_NAME)
    end

    def self.lsn_path(dump_dir = Karma.config.dump_dir) : String
      File.join(File.expand_path(dump_dir), LSN_FILE_NAME)
    end

    def self.segment_path(dump_dir : String, first_lsn : UInt64) : String
      File.join(File.expand_path(dump_dir), "#{FILE_NAME}.#{first_lsn.to_s.rjust(20, '0')}#{SEGMENT_EXTENSION}")
    end

    def self.segment_index_path(segment_path : String) : String
      "#{segment_path}#{INDEX_EXTENSION}"
    end

    def self.segment_paths(dump_dir = Karma.config.dump_dir) : Array(String)
      paths(dump_dir).select { |file_path| file_path.ends_with?(SEGMENT_EXTENSION) }
    end

    def self.paths(dump_dir = Karma.config.dump_dir) : Array(String)
      dump_dir = File.expand_path(dump_dir)
      mtime = directory_mtime(dump_dir)

      @@paths_cache_mutex.synchronize do
        if @@paths_cache_dir == dump_dir && @@paths_cache_mtime == mtime
          return @@paths_cache_paths.dup
        end
      end

      files = segment_paths_uncached(dump_dir)
      active_path = path(dump_dir)
      files << active_path if File.exists?(active_path)

      @@paths_cache_mutex.synchronize do
        @@paths_cache_dir = dump_dir
        @@paths_cache_mtime = mtime
        @@paths_cache_paths = files
      end
      files.dup
    end

    def self.bytes(dump_dir = Karma.config.dump_dir) : Int64
      paths(dump_dir).sum(0_i64) { |file_path| File.size(file_path) }
    end

    def self.segment_first_lsn(file_path : String) : UInt64?
      basename = File.basename(file_path)
      prefix = "#{FILE_NAME}."
      return nil unless basename.starts_with?(prefix)
      return nil unless basename.ends_with?(SEGMENT_EXTENSION)

      value = basename[prefix.bytesize, basename.bytesize - prefix.bytesize - SEGMENT_EXTENSION.bytesize]
      value.to_u64
    rescue ArgumentError
      nil
    end

    private def self.reset_paths_cache(dump_dir : String? = nil) : Nil
      expanded_dir = dump_dir.try { |dir| File.expand_path(dir) }
      @@paths_cache_mutex.synchronize do
        return if expanded_dir && @@paths_cache_dir != expanded_dir

        @@paths_cache_dir = nil
        @@paths_cache_mtime = nil
        @@paths_cache_paths = [] of String
      end
    end

    private def self.directory_mtime(dump_dir : String) : Time?
      return nil unless Dir.exists?(dump_dir)

      File.info(dump_dir).modification_time
    rescue File::Error
      nil
    end

    private def self.segment_paths_uncached(dump_dir : String) : Array(String)
      dump_dir = File.expand_path(dump_dir)
      pattern = File.join(dump_dir, "#{FILE_NAME}.*#{SEGMENT_EXTENSION}")
      segments = [] of Tuple(UInt64, String)
      Dir.glob(pattern).each do |file_path|
        next unless File.file?(file_path)
        first_lsn = segment_first_lsn(file_path)
        next if first_lsn.nil?

        segments << {first_lsn, file_path}
      end

      segments
        .sort { |a, b| a[0] <=> b[0] }
        .map { |segment| segment[1] }
    end

    def self.persist?(directive : Commands::Directive) : Bool
      Commands.mutating?(directive) && directive.command != "recovery_checkpoint"
    end
  end
end

require "./wal/serializer"
require "./wal/lsn"
require "./wal/entry"
require "./wal/store"
require "./wal/replay"
