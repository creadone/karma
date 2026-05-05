require "json"
require "random/secure"

module Karma
  module Wal
    LSN_MUTEX = Mutex.new
    @@current_lsn = 0_u64
    @@loaded_lsn_dir : String?

    def self.current_lsn(dump_dir = Karma.config.dump_dir) : UInt64
      LSN_MUTEX.synchronize do
        ensure_lsn_loaded(dump_dir)
        @@current_lsn
      end
    end

    private def self.with_next_lsn(dump_dir : String, &) : Nil
      LSN_MUTEX.synchronize do
        ensure_lsn_loaded(dump_dir)
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
      wal_path = path(dump_dir)
      return 0_u64 unless File.exists?(wal_path)

      max_lsn = 0_u64
      File.each_line(wal_path) do |line|
        next if line.blank?

        object = JSON.parse(line).as_h
        lsn = object["lsn"]?.try(&.as_i64?.try(&.to_u64)) || 0_u64
        max_lsn = lsn if lsn > max_lsn
      end
      max_lsn
    end

    private def self.persist_lsn(dump_dir : String, lsn : UInt64) : Nil
      dump_dir = File.expand_path(dump_dir)
      Dir.mkdir_p(dump_dir) unless Dir.exists?(dump_dir)

      file_path = lsn_path(dump_dir)
      temp_path = File.join(
        dump_dir,
        ".#{LSN_FILE_NAME}.#{Process.pid}.#{Random::Secure.hex(8)}.tmp"
      )

      File.open(temp_path, "w") do |io|
        io.puts lsn
        io.flush
        io.fsync if fsync?
      end
      File.rename(temp_path, file_path)
    ensure
      File.delete(temp_path) if temp_path && File.exists?(temp_path)
    end
  end
end
