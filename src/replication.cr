require "json"
require "random/secure"

module Karma
  module Replication
    LSN_FILE_NAME = "karma.replication.lsn"
    LSN_MUTEX     = Mutex.new
    METRICS_MUTEX = Mutex.new

    @@replayed_lsn = 0_u64
    @@loaded_lsn_dir : String?
    @@entries_applied = 0_i64
    @@last_received_unix = 0_i64

    def self.apply(entries : Array(Karma::Wal::Entry), cluster : Cluster, dump_dir = Karma.config.dump_dir) : UInt64
      Karma::State.synchronize do
        current = replayed_lsn(dump_dir)

        entries.each do |entry|
          next if entry.lsn <= current
          unless entry.lsn == current + 1
            raise Karma::Error.new("replication_gap", "Replication gap: expected LSN #{current + 1}, got #{entry.lsn}")
          end

          apply_entry(entry, cluster)
          current = entry.lsn
          persist_replayed_lsn(dump_dir, current)
          record_applied(current)
        end

        current
      end
    end

    def self.checkpoint(lsn : UInt64, dump_dir = Karma.config.dump_dir) : UInt64
      persist_replayed_lsn(dump_dir, lsn)
      lsn
    end

    def self.replayed_lsn(dump_dir = Karma.config.dump_dir) : UInt64
      LSN_MUTEX.synchronize do
        ensure_lsn_loaded(dump_dir)
        @@replayed_lsn
      end
    end

    def self.status(master_lsn : UInt64 = Karma::Wal.current_lsn, dump_dir = Karma.config.dump_dir)
      replayed = replayed_lsn(dump_dir)
      {
        replayed_lsn:       replayed,
        source_lsn:         master_lsn,
        lag_entries:        lag_entries(master_lsn, replayed),
        entries_applied:    entries_applied,
        last_received_unix: last_received_unix,
      }
    end

    def self.reset! : Nil
      LSN_MUTEX.synchronize do
        @@replayed_lsn = 0_u64
        @@loaded_lsn_dir = nil
      end
      METRICS_MUTEX.synchronize do
        @@entries_applied = 0_i64
        @@last_received_unix = 0_i64
      end
    end

    def self.lsn_path(dump_dir = Karma.config.dump_dir) : String
      File.join(dump_dir, LSN_FILE_NAME)
    end

    private def self.apply_entry(entry : Karma::Wal::Entry, cluster : Cluster) : Nil
      response = Karma::Commands.call(
        entry.entry.to_json,
        cluster,
        persist: false,
        authorize: false,
        synchronize: false,
        track_legacy: false,
        enforce_request_size: false,
        enforce_role: false
      )
      parsed_response = JSON.parse(response)
      return if parsed_response["success"].as_bool

      raise Karma::Error.new("replication_error", "Cannot apply WAL entry #{entry.lsn}: #{parsed_response["response"]}")
    end

    private def self.lag_entries(master_lsn : UInt64, replayed_lsn : UInt64) : UInt64
      return 0_u64 unless Karma.config.role == "slave"
      return 0_u64 if replayed_lsn >= master_lsn

      master_lsn - replayed_lsn
    end

    private def self.record_applied(lsn : UInt64) : Nil
      METRICS_MUTEX.synchronize do
        @@entries_applied += 1
        @@last_received_unix = Time.utc.to_unix
      end
    end

    private def self.entries_applied : Int64
      METRICS_MUTEX.synchronize { @@entries_applied }
    end

    private def self.last_received_unix : Int64
      METRICS_MUTEX.synchronize { @@last_received_unix }
    end

    private def self.ensure_lsn_loaded(dump_dir : String) : Nil
      dump_dir = File.expand_path(dump_dir)
      return if @@loaded_lsn_dir == dump_dir

      @@replayed_lsn = read_lsn_file(dump_dir)
      @@loaded_lsn_dir = dump_dir
    end

    private def self.read_lsn_file(dump_dir : String) : UInt64
      file_path = lsn_path(dump_dir)
      return 0_u64 unless File.exists?(file_path)

      text = File.read(file_path).strip
      return 0_u64 if text.empty?

      text.to_u64
    rescue ArgumentError
      raise Karma::Error.new("validation_error", "Invalid replication LSN file #{file_path}")
    end

    private def self.persist_replayed_lsn(dump_dir : String, lsn : UInt64) : Nil
      LSN_MUTEX.synchronize do
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
          io.fsync if Karma::Wal.fsync?
        end
        File.rename(temp_path, file_path)
        @@replayed_lsn = lsn
        @@loaded_lsn_dir = dump_dir
      ensure
        File.delete(temp_path) if temp_path && File.exists?(temp_path)
      end
    end
  end
end
