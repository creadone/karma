require "./server/client_session"

module Karma
  class Server
    def initialize(@cluster : Cluster)
      @server = TCPServer.new(Karma.config.host, Karma.config.port)
      @server.tcp_nodelay = Karma.config.tcp_nodelay
      @stopping = false
      @clients = [] of TCPSocket
      @clients_mutex = Mutex.new
    end

    def handle(client : TCPSocket)
      begin
        ClientSession.new(client, @cluster).run
      ensure
        unregister(client)
        close_client(client)
      end
    end

    def start!
      while client = @server.accept?
        if @stopping
          close_client(client)
          next
        end

        register(client)
        spawn handle(client)
      end
    rescue ex
      raise ex unless @stopping
    end

    def stop! : Nil
      @stopping = true
      initial_clients = active_client_count
      Karma::Log.info("server.stop_begin", "active_clients=#{initial_clients}")

      close_listener
      if drain_clients(Karma.config.shutdown_timeout_seconds.seconds)
        Karma::Log.info("server.drain_complete", "active_clients=0")
        return
      end

      forced_clients = active_client_count
      Karma::Log.info("server.drain_timeout", "active_clients=#{forced_clients}")
      close_active_clients
      drain_clients(1.second)
      Karma::Log.info("server.force_close", "closed_clients=#{forced_clients} remaining_clients=#{active_client_count}")
    end

    private def close_listener : Nil
      @server.close
    rescue
    end

    private def register(client : TCPSocket) : Nil
      @clients_mutex.synchronize do
        @clients << client
      end
    end

    private def unregister(client : TCPSocket) : Nil
      @clients_mutex.synchronize do
        @clients.delete(client)
      end
    end

    private def active_clients : Array(TCPSocket)
      @clients_mutex.synchronize { @clients.dup }
    end

    private def active_client_count : Int32
      @clients_mutex.synchronize { @clients.size }
    end

    private def drain_clients(timeout : Time::Span) : Bool
      deadline = Time.monotonic + timeout
      until active_client_count == 0
        return false if timeout <= Time::Span.zero || Time.monotonic >= deadline

        sleep 10.milliseconds
      end

      true
    end

    private def close_active_clients : Nil
      active_clients.each { |client| close_client(client) }
    end

    private def close_client(client : TCPSocket) : Nil
      client.close
    rescue
    end
  end
end
