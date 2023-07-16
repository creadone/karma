module Karma
  class Server
    def initialize(@cluster : Cluster)
      @server = TCPServer.new(Karma.config.host, Karma.config.port)
      @server.tcp_nodelay = Karma.config.tcp_nodelay
    end

    def handle(client)
      while message = client.gets
        if answer = Commands.call(message, @cluster)
          client.send(answer)
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