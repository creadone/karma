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