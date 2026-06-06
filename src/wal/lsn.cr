require "json"

module Karma
  module Wal
    LSN_MUTEX = Mutex.new
    @@current_lsn = 0_u64
    @@loaded_lsn_dir : String?
    @@wal_io : File?
    @@wal_io_dir : String?
    @@lsn_io : File?
    @@lsn_io_dir : String?

    def self.current_lsn(dump_dir = Karma.config.dump_dir) : UInt64
      LSN_MUTEX.synchronize do
        ensure_lsn_loaded(dump_dir)
        @@current_lsn
      end
    end

    def self.reset! : Nil
      LSN_MUTEX.synchronize do
        close_wal_io
        close_lsn_io
        reset_paths_cache
        reset_entry_index
        @@current_lsn = 0_u64
        @@loaded_lsn_dir = nil
      end
    end

    private def self.with_next_lsn(dump_dir : String, &) : Nil
      LSN_MUTEX.synchronize do
        dump_dir = File.expand_path(dump_dir)
        ensure_lsn_loaded(dump_dir)
        rotate_wal_if_needed(dump_dir)
        lsn = @@current_lsn + 1
        persist_lsn(dump_dir, lsn)
        yield lsn
        @@current_lsn = lsn
      end
    end

    private def self.ensure_lsn_loaded(dump_dir : String) : Nil
      dump_dir = File.expand_path(dump_dir)
      return if @@loaded_lsn_dir == dump_dir

      @@current_lsn = Math.max(read_lsn_file(dump_dir), scan_wal_lsn(dump_dir))
      @@loaded_lsn_dir = dump_dir
    end

    private def self.read_lsn_file(dump_dir : String) : UInt64
      file_path = lsn_path(dump_dir)
      return 0_u64 unless File.exists?(file_path)

      text = File.read(file_path).strip
      return 0_u64 if text.empty?

      text.to_u64
    rescue ArgumentError
      raise Karma::Error.new("validation_error", "Invalid WAL LSN file #{file_path}")
    end

    private def self.scan_wal_lsn(dump_dir : String) : UInt64
      max_lsn = 0_u64
      paths(dump_dir).each do |wal_path|
        File.each_line(wal_path) do |line|
          next if line.blank?

          object = JSON.parse(line).as_h
          lsn = object["lsn"]?.try(&.as_i64?.try(&.to_u64)) || 0_u64
          max_lsn = lsn if lsn > max_lsn
        end
      end
      max_lsn
    end

    private def self.wal_io(dump_dir : String) : File
      dump_dir = File.expand_path(dump_dir)
      Dir.mkdir_p(dump_dir) unless Dir.exists?(dump_dir)

      if @@wal_io_dir != dump_dir
        close_wal_io
      end

      @@wal_io ||= File.open(path(dump_dir), "a").tap do |io|
        io.seek(0, IO::Seek::End)
        @@wal_io_dir = dump_dir
      end
    end

    private def self.lsn_io(dump_dir : String) : File
      dump_dir = File.expand_path(dump_dir)
      Dir.mkdir_p(dump_dir) unless Dir.exists?(dump_dir)

      if @@lsn_io_dir != dump_dir
        close_lsn_io
      end

      @@lsn_io ||= begin
        mode = File.exists?(lsn_path(dump_dir)) ? "r+" : "w+"
        File.open(lsn_path(dump_dir), mode).tap do
          @@lsn_io_dir = dump_dir
        end
      end
    end

    private def self.close_wal_io(dump_dir : String? = nil) : Nil
      return if dump_dir && @@wal_io_dir != File.expand_path(dump_dir)

      io = @@wal_io
      @@wal_io = nil
      @@wal_io_dir = nil
      io.try(&.close)
    rescue
    end

    private def self.close_lsn_io(dump_dir : String? = nil) : Nil
      return if dump_dir && @@lsn_io_dir != File.expand_path(dump_dir)

      io = @@lsn_io
      @@lsn_io = nil
      @@lsn_io_dir = nil
      io.try(&.close)
    rescue
    end

    private def self.persist_lsn(dump_dir : String, lsn : UInt64) : Nil
      io = lsn_io(dump_dir)
      io.truncate(0)
      io.rewind
      io.puts lsn
      io.flush
      io.fsync if fsync?
    end
  end
end
