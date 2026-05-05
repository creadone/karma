require "./server/client_session"

module Karma
  class Server
    def initialize(@cluster : Cluster)
      @server = TCPServer.new(Karma.config.host, Karma.config.port)
      @server.tcp_nodelay = Karma.config.tcp_nodelay
    end

    def handle(client)
      ClientSession.new(client, @cluster).run
    end

    def start!
      while client = @server.accept?
        spawn handle(client)
      end
    end
  end
end
