require "option_parser"

module Karma
  module Cli
    def self.parse!(args = ARGV) : Nil
      Karma.config.load_env!

      parser = OptionParser.new do |parser|
        parser.banner = "Usage: karma [arguments]"

        parser.on("-b host", "--bind=host", "Host to bind (default: #{Karma.config.host})") do |host|
          Karma.config.host = host.to_s
        end

        parser.on("-p port", "--port=port", "Port to listen for connection (default: #{Karma.config.port})") do |port|
          Karma.config.port = int_flag(port, "--port")
        end

        parser.on("-d path", "--directory=path", "Directory for storing and loading dumps (default: #{Karma.config.dump_dir})") do |path|
          Karma.config.dump_dir = path.to_s
        end

        parser.on("--role=role", "Replication role: master or slave (default: #{Karma.config.role})") do |role|
          Karma.config.role = role
        end

        parser.on("-r flag", "--restore=flag", "Load last state from dumps (default: #{Karma.config.restore})") do |flag|
          Karma.config.restore = bool_flag(flag, "--restore")
        end

        parser.on("-n flag", "--nodelay=flag", "Disable Nagle's algorithm (default: #{Karma.config.tcp_nodelay})") do |flag|
          Karma.config.tcp_nodelay = bool_flag(flag, "--nodelay")
        end

        parser.on("-w flag", "--wal=flag", "Enable write-ahead log (default: #{Karma.config.wal})") do |flag|
          Karma.config.wal = bool_flag(flag, "--wal")
        end

        parser.on("--wal-fsync=flag", "Fsync write-ahead log entries (default: #{Karma.config.wal_fsync})") do |flag|
          Karma.config.wal_fsync = bool_flag(flag, "--wal-fsync")
        end

        parser.on("--wal-segment-bytes=bytes", "Rotate active WAL after this many bytes; 0 disables rotation (default: #{Karma.config.wal_segment_bytes})") do |bytes|
          Karma.config.wal_segment_bytes = int_flag(bytes, "--wal-segment-bytes")
        end

        parser.on("--max-request-bytes=bytes", "Maximum request line size (default: #{Karma.config.max_request_bytes})") do |bytes|
          Karma.config.max_request_bytes = int_flag(bytes, "--max-request-bytes")
        end

        parser.on("--max-response-bytes=bytes", "Maximum response size; 0 disables the limit (default: #{Karma.config.max_response_bytes})") do |bytes|
          Karma.config.max_response_bytes = int_flag(bytes, "--max-response-bytes")
        end

        parser.on("--read-timeout=seconds", "Client read timeout in seconds (default: #{Karma.config.read_timeout_seconds})") do |seconds|
          Karma.config.read_timeout_seconds = int_flag(seconds, "--read-timeout")
        end

        parser.on("--write-timeout=seconds", "Client write timeout in seconds (default: #{Karma.config.write_timeout_seconds})") do |seconds|
          Karma.config.write_timeout_seconds = int_flag(seconds, "--write-timeout")
        end

        parser.on("--query-timeout-ms=ms", "Tree-level read timeout in milliseconds; 0 disables the limit (default: #{Karma.config.query_timeout_ms})") do |ms|
          Karma.config.query_timeout_ms = int_flag(ms, "--query-timeout-ms")
        end

        parser.on("--shutdown-timeout=seconds", "Seconds to wait for active clients on shutdown (default: #{Karma.config.shutdown_timeout_seconds})") do |seconds|
          Karma.config.shutdown_timeout_seconds = int_flag(seconds, "--shutdown-timeout")
        end

        parser.on("--auth-token=token", "Require token field in client commands") do |token|
          Karma.config.auth_token = token
        end

        parser.on("--read-auth-token=token", "Allow token field to authorize read-only commands") do |token|
          Karma.config.read_auth_token = token
        end

        parser.on("--dump-retention-per-tree=count", "Dumps to keep per tree after dump_all (default: #{Karma.config.dump_retention_per_tree})") do |count|
          Karma.config.dump_retention_per_tree = int_flag(count, "--dump-retention-per-tree")
        end

        parser.on("--replication-source-host=host", "Master host for slave WAL polling") do |host|
          Karma.config.replication_source_host = host
        end

        parser.on("--replication-source-port=port", "Master port for slave WAL polling (default: #{Karma.config.replication_source_port})") do |port|
          Karma.config.replication_source_port = int_flag(port, "--replication-source-port")
        end

        parser.on("--replication-token=token", "Token used by slave polling requests") do |token|
          Karma.config.replication_token = token
        end

        parser.on("--replication-poll-interval-ms=ms", "Slave polling interval in milliseconds (default: #{Karma.config.replication_poll_interval_ms})") do |ms|
          Karma.config.replication_poll_interval_ms = int_flag(ms, "--replication-poll-interval-ms")
        end

        parser.on("--replication-batch-size=count", "Maximum WAL entries per slave poll (default: #{Karma.config.replication_batch_size})") do |count|
          Karma.config.replication_batch_size = int_flag(count, "--replication-batch-size")
        end

        parser.on("--idempotency-max-records=count", "Maximum idempotency records to keep (default: #{Karma.config.idempotency_max_records})") do |count|
          Karma.config.idempotency_max_records = int_flag(count, "--idempotency-max-records")
        end

        parser.on("--idempotency-max-age-seconds=seconds", "Maximum idempotency record age; 0 disables age pruning (default: #{Karma.config.idempotency_max_age_seconds})") do |seconds|
          Karma.config.idempotency_max_age_seconds = int_flag(seconds, "--idempotency-max-age-seconds")
        end

        parser.on("--log=flag", "Enable structured JSON logs (default: #{Karma.config.log})") do |flag|
          Karma.config.log = bool_flag(flag, "--log")
        end

        parser.on("-h", "--help", "Show this help") do
          puts parser
          exit
        end

        parser.invalid_option do |flag|
          STDERR.puts "ERROR: #{flag} is not a valid option."
          STDERR.puts parser
          exit(1)
        end
      end

      parser.parse(args)
      Karma.config.validate!
    end

    private def self.int_flag(value : String, option : String) : Int32
      value.to_i32
    rescue ArgumentError
      raise Karma::Error.new("validation_error", "#{option} must be an integer")
    end

    private def self.bool_flag(value : String, option : String) : Bool
      case value
      when "true"
        true
      when "false"
        false
      else
        raise Karma::Error.new("validation_error", "#{option} must be true or false")
      end
    end
  end
end
