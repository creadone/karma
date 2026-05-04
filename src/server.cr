module Karma
  class Server
    def initialize(@cluster : Cluster)
      @server = TCPServer.new(Karma.config.host, Karma.config.port)
      @server.tcp_nodelay = Karma.config.tcp_nodelay
    end

    def handle(client)
      client.read_timeout = Karma.config.read_timeout_seconds.seconds if Karma.config.read_timeout_seconds > 0
      client.write_timeout = Karma.config.write_timeout_seconds.seconds if Karma.config.write_timeout_seconds > 0

      while message = client.gets('\n', Karma.config.max_request_bytes + 1, chomp: true)
        if message.bytesize > Karma.config.max_request_bytes
          client.send("#{Karma::Protocol.error("request_too_large", "Request exceeds #{Karma.config.max_request_bytes} bytes")}\r\n")
          break
        end

        if answer = Commands.call(message, @cluster)
          client.send("#{answer}\r\n")
        end
      end
    end

    def start!
      while client = @server.accept?
        spawn handle(client)
      end
    end
  end
end
