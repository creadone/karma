require "option_parser"

module Karma
  module Cli
    parser = OptionParser.new do |parser|
      parser.banner = "Usage: karma [arguments]"

      parser.on("-b host", "--bind=host", "Host to bind (default: #{Karma.config.host})") do |host|
        Karma.config.host = host.to_s
      end

      parser.on("-p port", "--port=port", "Port to listen for connection (default: #{Karma.config.port})") do |port|
        Karma.config.port = port.to_i32
      end

      parser.on("-d path", "--directory=path", "Directory for storing and loading dumps (default: #{Karma.config.dump_dir})") do |path|
        Karma.config.dump_dir = path.to_s
      end

      parser.on("-r flag", "--restore=flag", "Load last state from dumps (default: #{Karma.config.restore})") do |flag|
        Karma.config.restore = (flag == "true")
      end

      parser.on("-n flag", "--nodelay=flag", "Disable Nagle's algorithm (default: #{Karma.config.tcp_nodelay})") do |flag|
        Karma.config.tcp_nodelay = (flag == "true")
      end

      parser.on("-w flag", "--wal=flag", "Enable write-ahead log (default: #{Karma.config.wal})") do |flag|
        Karma.config.wal = (flag == "true")
      end

      parser.on("--wal-fsync=flag", "Fsync write-ahead log entries (default: #{Karma.config.wal_fsync})") do |flag|
        Karma.config.wal_fsync = (flag == "true")
      end

      parser.on("--max-request-bytes=bytes", "Maximum request line size (default: #{Karma.config.max_request_bytes})") do |bytes|
        Karma.config.max_request_bytes = bytes.to_i32
      end

      parser.on("--read-timeout=seconds", "Client read timeout in seconds (default: #{Karma.config.read_timeout_seconds})") do |seconds|
        Karma.config.read_timeout_seconds = seconds.to_i32
      end

      parser.on("--write-timeout=seconds", "Client write timeout in seconds (default: #{Karma.config.write_timeout_seconds})") do |seconds|
        Karma.config.write_timeout_seconds = seconds.to_i32
      end

      parser.on("--auth-token=token", "Require token field in client commands") do |token|
        Karma.config.auth_token = token
      end

      parser.on("--dump-retention-per-tree=count", "Dumps to keep per tree after dump_all (default: #{Karma.config.dump_retention_per_tree})") do |count|
        Karma.config.dump_retention_per_tree = count.to_i32
      end

      parser.on("--log=flag", "Enable structured JSON logs (default: #{Karma.config.log})") do |flag|
        Karma.config.log = (flag == "true")
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

    parser.parse
  end
end
