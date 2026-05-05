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
        snapshots = latest_snapshots
        return 0_u64 if snapshots.empty?

        snapshots.each do |snapshot|
          fetch_and_install(snapshot["file"].as_s, dump_dir)
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

      private def latest_snapshots : Array(JSON::Any)
        request(command_json("snapshot.info"))["latest_by_tree"].as_a
      end

      private def fetch_and_install(file_name : String, dump_dir : String) : String
        response = request(command_json("snapshot.fetch", file_name))
        metadata = Karma::Backup::SnapshotMetadata.from_response(response["metadata"])
        data = Base64.decode(response["data_base64"].as_s)

        Karma::Backup.install(file_name, data, metadata, dump_dir)
      end

      private def command_json(op : String, file_name : String? = nil) : String
        JSON.build do |json|
          json.object do
            json.field "v", 2
            json.field "op", op
            json.field "file", file_name if file_name
            json.field "token", @token if @token
          end
        end
      end
    end
  end
end
