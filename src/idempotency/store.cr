require "base64"
require "json"
require "random/secure"

module Karma
  module Idempotency
    SNAPSHOT_FILE_NAME = "karma.idempotency.json"

    struct SnapshotMetadata
      include JSON::Serializable

      getter file : String
      getter timestamp : Int64
      getter last_lsn : UInt64
      getter bytes : Int64
      getter record_count : Int32
      getter committed_stream_count : Int32

      def initialize(@file : String, @timestamp : Int64, @last_lsn : UInt64, @bytes : Int64, @record_count : Int32, @committed_stream_count : Int32)
      end

      def self.from_response(object : JSON::Any) : SnapshotMetadata
        hash = object.as_h
        new(
          hash["file"].as_s,
          hash["timestamp"].as_i64,
          hash["last_lsn"].as_i64.to_u64,
          hash["bytes"].as_i64,
          hash["record_count"].as_i,
          hash["committed_stream_count"].as_i
        )
      end

      def to_response
        {
          file:                   file,
          timestamp:              timestamp,
          bytes:                  bytes,
          last_lsn:               last_lsn,
          record_count:           record_count,
          committed_stream_count: committed_stream_count,
        }
      end
    end

    struct SnapshotPayload
      include JSON::Serializable

      getter records : Array(Record)
      getter committed_streams : Array(CommittedStream)

      def initialize(@records : Array(Record), @committed_streams : Array(CommittedStream))
      end
    end

    def self.snapshot_path(dump_dir = Karma.config.dump_dir) : String
      File.join(File.expand_path(dump_dir), SNAPSHOT_FILE_NAME)
    end

    def self.metadata_path(dump_dir = Karma.config.dump_dir) : String
      "#{snapshot_path(dump_dir)}#{Karma::Backup::METADATA_EXTENSION}"
    end

    def self.dump(dump_dir = Karma.config.dump_dir, last_lsn = snapshot_lsn) : SnapshotMetadata
      dump_dir = File.expand_path(dump_dir)
      Dir.mkdir_p(dump_dir) unless Dir.exists?(dump_dir)

      path = snapshot_path(dump_dir)
      temp_path = File.join(dump_dir, ".#{SNAPSHOT_FILE_NAME}.#{Process.pid}.#{Random::Secure.hex(8)}.tmp")
      payload = SnapshotPayload.new(records, committed_streams)

      File.open(temp_path, "w") do |io|
        payload.to_json(io)
        io.puts
        io.flush
        io.fsync
      end
      File.rename(temp_path, path)
      write_metadata(dump_dir, last_lsn)
    ensure
      File.delete(temp_path) if temp_path && File.exists?(temp_path)
    end

    def self.restore(dump_dir = Karma.config.dump_dir) : Nil
      path = snapshot_path(dump_dir)
      unless File.exists?(path)
        replace_records([] of Record)
        replace_committed_streams([] of CommittedStream)
        return
      end

      payload = SnapshotPayload.from_json(File.read(path))
      replace_records(payload.records)
      replace_committed_streams(payload.committed_streams)
    end

    def self.info(dump_dir = Karma.config.dump_dir) : SnapshotMetadata?
      path = snapshot_path(dump_dir)
      return nil unless File.exists?(path)

      read_metadata(dump_dir)
    end

    def self.fetch_chunk(offset : UInt64 = 0_u64, limit : Int32 = Karma::Backup::SNAPSHOT_CHUNK_DEFAULT_BYTES, dump_dir = Karma.config.dump_dir)
      path = snapshot_path(dump_dir)
      raise Karma::Error.new("not_found", "Idempotency snapshot not found") unless File.exists?(path)
      validate_chunk_limit!(limit)

      total_bytes = File.size(path).to_u64
      raise Karma::Error.new("validation_error", "Field offset exceeds idempotency snapshot size") if offset > total_bytes

      bytes_to_read = Math.min(limit.to_u64, total_bytes - offset).to_i
      data = Bytes.new(bytes_to_read)
      bytes_read = 0

      File.open(path, "rb") do |file|
        file.seek(offset.to_i64)
        bytes_read = file.read(data)
      end

      chunk = data[0, bytes_read]
      next_offset = offset + bytes_read.to_u64
      {
        metadata:    read_metadata(dump_dir).to_response,
        offset:      offset,
        limit:       limit,
        bytes:       bytes_read,
        total_bytes: total_bytes,
        next_offset: next_offset,
        done:        next_offset >= total_bytes,
        data_base64: Base64.strict_encode(chunk),
      }
    end

    def self.install_stream(metadata : SnapshotMetadata, dump_dir = Karma.config.dump_dir, &) : String
      raise Karma::Error.new("validation_error", "Idempotency snapshot metadata file mismatch") unless metadata.file == SNAPSHOT_FILE_NAME

      dump_dir = File.expand_path(dump_dir)
      Dir.mkdir_p(dump_dir) unless Dir.exists?(dump_dir)
      path = snapshot_path(dump_dir)
      temp_path = File.join(dump_dir, ".#{SNAPSHOT_FILE_NAME}.#{Process.pid}.#{Random::Secure.hex(8)}.tmp")

      File.open(temp_path, "wb") do |io|
        yield io
        io.flush
        io.fsync
      end
      File.rename(temp_path, path)
      write_metadata(dump_dir, metadata.last_lsn)
      path
    ensure
      File.delete(temp_path) if temp_path && File.exists?(temp_path)
    end

    private def self.snapshot_lsn : UInt64
      Karma.config.role == "slave" ? Karma::Replication.replayed_lsn : Karma::Wal.current_lsn
    end

    private def self.write_metadata(dump_dir : String, last_lsn : UInt64) : SnapshotMetadata
      path = snapshot_path(dump_dir)
      metadata = SnapshotMetadata.new(
        SNAPSHOT_FILE_NAME,
        Time.utc.to_unix,
        last_lsn,
        File.exists?(path) ? File.size(path) : 0_i64,
        records.size,
        committed_streams.size
      )
      metadata_path = metadata_path(dump_dir)
      temp_path = File.join(dump_dir, ".#{File.basename(metadata_path)}.#{Process.pid}.#{Random::Secure.hex(8)}.tmp")

      File.open(temp_path, "w") do |io|
        metadata.to_json(io)
        io.puts
        io.flush
        io.fsync
      end
      File.rename(temp_path, metadata_path)
      metadata
    ensure
      File.delete(temp_path) if temp_path && File.exists?(temp_path)
    end

    private def self.read_metadata(dump_dir : String) : SnapshotMetadata
      metadata_file = metadata_path(dump_dir)
      return SnapshotMetadata.from_json(File.read(metadata_file)) if File.exists?(metadata_file)

      path = snapshot_path(dump_dir)
      SnapshotMetadata.new(
        SNAPSHOT_FILE_NAME,
        File.exists?(path) ? File.info(path).modification_time.to_unix : 0_i64,
        0_u64,
        File.exists?(path) ? File.size(path) : 0_i64,
        records.size,
        committed_streams.size
      )
    end

    private def self.validate_chunk_limit!(limit : Int32) : Nil
      raise Karma::Error.new("validation_error", "Field limit must be greater than 0") if limit <= 0
      raise Karma::Error.new("validation_error", "Field limit exceeds max size") if limit > Karma::Backup::SNAPSHOT_CHUNK_MAX_BYTES
    end
  end
end
