require "base64"
require "json"
require "socket"

module Karma
  module Replication
    class SnapshotClient
      def self.build? : SnapshotClient?
        return nil unless Karma.config.role == "slave"
        return nil unless host = Karma.config.replication_source_host

        new(host, Karma.config.replication_source_port, Karma.config.replication_token)
      end

      def initialize(@host : String, @port : Int32, @token : String? = nil)
      end

      def bootstrap_files(dump_dir = Karma.config.dump_dir) : UInt64
        info = snapshot_info
        snapshots = info["latest_by_tree"].as_a
        idempotency_snapshot = info["idempotency_snapshot"]?
        return 0_u64 if snapshots.empty? && (idempotency_snapshot.nil? || idempotency_snapshot.raw.nil?)

        snapshots.each do |snapshot|
          fetch_and_install(snapshot["file"].as_s, dump_dir)
        end
        if idempotency_snapshot
          fetch_and_install_idempotency(idempotency_snapshot, dump_dir) unless idempotency_snapshot.raw.nil?
        end
        Karma::Backup.restore_lsn(dump_dir)
      end

      protected def request(payload : String) : JSON::Any
        socket = TCPSocket.new(@host, @port)
        socket.read_timeout = Karma.config.read_timeout_seconds.seconds if Karma.config.read_timeout_seconds > 0
        socket.write_timeout = Karma.config.write_timeout_seconds.seconds if Karma.config.write_timeout_seconds > 0
        socket << payload << "\n"
        line = socket.gets
        raise Karma::Error.new("replication_error", "Master closed connection without response") unless line

        parsed = JSON.parse(line)
        unless parsed["success"].as_bool
          raise Karma::Error.new("replication_error", "Master rejected snapshot request: #{parsed["response"]}")
        end

        parsed["response"]
      ensure
        socket.try(&.close)
      end

      private def snapshot_info : JSON::Any
        request(command_json("snapshot.info"))
      end

      private def fetch_and_install(file_name : String, dump_dir : String) : String
        first_chunk = request_chunk(file_name, 0_u64)
        metadata = Karma::Backup::SnapshotMetadata.from_response(first_chunk["metadata"])

        Karma::Backup.install_stream(file_name, metadata, dump_dir) do |io|
          chunk = first_chunk
          loop do
            ensure_same_snapshot!(metadata, chunk)
            io.write Base64.decode(chunk["data_base64"].as_s)
            break if chunk["done"].as_bool

            chunk = request_chunk(file_name, chunk["next_offset"].as_i64.to_u64)
          end
        end
      end

      private def request_chunk(file_name : String, offset : UInt64) : JSON::Any
        request(command_json(
          "snapshot.fetch_chunk",
          file_name,
          offset,
          Karma::Backup::SNAPSHOT_CHUNK_DEFAULT_BYTES
        ))
      end

      private def fetch_and_install_idempotency(metadata_response : JSON::Any, dump_dir : String) : String
        metadata = Karma::Idempotency::SnapshotMetadata.from_response(metadata_response)
        first_chunk = request_idempotency_chunk(0_u64)

        Karma::Idempotency.install_stream(metadata, dump_dir) do |io|
          chunk = first_chunk
          loop do
            ensure_same_idempotency_snapshot!(metadata, chunk)
            io.write Base64.decode(chunk["data_base64"].as_s)
            break if chunk["done"].as_bool

            chunk = request_idempotency_chunk(chunk["next_offset"].as_i64.to_u64)
          end
        end
      end

      private def request_idempotency_chunk(offset : UInt64) : JSON::Any
        request(command_json(
          "idempotency.snapshot_fetch_chunk",
          nil,
          offset,
          Karma::Backup::SNAPSHOT_CHUNK_DEFAULT_BYTES
        ))
      end

      private def ensure_same_snapshot!(expected : Karma::Backup::SnapshotMetadata, response : JSON::Any) : Nil
        actual = Karma::Backup::SnapshotMetadata.from_response(response["metadata"])
        return if actual.file == expected.file && actual.last_lsn == expected.last_lsn && actual.bytes == expected.bytes

        raise Karma::Error.new("replication_error", "Snapshot changed during fetch")
      end

      private def ensure_same_idempotency_snapshot!(expected : Karma::Idempotency::SnapshotMetadata, response : JSON::Any) : Nil
        actual = Karma::Idempotency::SnapshotMetadata.from_response(response["metadata"])
        return if actual.file == expected.file && actual.last_lsn == expected.last_lsn && actual.bytes == expected.bytes

        raise Karma::Error.new("replication_error", "Idempotency snapshot changed during fetch")
      end

      private def command_json(op : String, file_name : String? = nil, offset : UInt64? = nil, limit : Int32? = nil) : String
        JSON.build do |json|
          json.object do
            json.field "v", 2
            json.field "op", op
            json.field "file", file_name if file_name
            json.field "offset", offset if offset
            json.field "limit", limit if limit
            json.field "token", @token if @token
          end
        end
      end
    end
  end
end
