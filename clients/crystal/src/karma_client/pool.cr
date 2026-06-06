module KarmaClient
  class Pool
    def initialize(size : Int32, @timeout : Time::Span, &@factory : -> Client)
      raise ConfigurationError.new("pool size must be greater than 0") unless size > 0

      @available = Channel(Client).new(size)
      @clients = [] of Client
      @closed = false
      @mutex = Mutex.new

      size.times do
        client = @factory.call
        @clients << client
        @available.send(client)
      end
    end

    def with(&)
      client = checkout
      begin
        yield client
      ensure
        checkin(client) if client
      end
    end

    def close : Nil
      clients = [] of Client
      @mutex.synchronize do
        return if @closed

        @closed = true
        clients = @clients.dup
      end

      clients.each(&.close)
    end

    private def checkout : Client
      raise PoolTimeout.new("Karma client pool is closed") if closed?

      if @timeout == Time::Span.zero
        @available.receive
      else
        select
        when client = @available.receive
          client
        when timeout(@timeout)
          raise PoolTimeout.new("Timed out waiting for a Karma client connection")
        end
      end
    end

    private def checkin(client : Client) : Nil
      if closed?
        client.close
      else
        @available.send(client)
      end
    end

    private def closed? : Bool
      @mutex.synchronize { @closed }
    end
  end
end
