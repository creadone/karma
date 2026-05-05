require "./server/client_session"

module Karma
  class Server
    def initialize(@cluster : Cluster)
      @server = TCPServer.new(Karma.config.host, Karma.config.port)
      @server.tcp_nodelay = Karma.config.tcp_nodelay
      @stopping = false
    end

    def handle(client)
      ClientSession.new(client, @cluster).run
    end

    def start!
      while client = @server.accept?
        spawn handle(client)
      end
    rescue ex
      raise ex unless @stopping
    end

    def stop! : Nil
      @stopping = true
      @server.close
    rescue
    end
  end
end
