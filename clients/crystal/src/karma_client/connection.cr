require "json"
require "socket"

module KarmaClient
  class Connection
    getter host : String
    getter port : Int32

    @socket : TCPSocket?

    def initialize(
      @host : String,
      @port : Int32,
      @connect_timeout : Time::Span,
      @read_timeout : Time::Span,
      @write_timeout : Time::Span,
      @tcp_nodelay : Bool = true,
    )
      @socket = nil
    end

    def request(payload : Hash(String, JSON::Any)) : String
      socket = ensure_connected!
      write_payload(socket, payload)
      read_response(socket)
    rescue ex : TimeoutError
      close
      raise ex
    rescue ex : IO::TimeoutError
      close
      raise TimeoutError.new("io", @read_timeout, host, port)
    rescue ex : IO::Error | Socket::Error
      close
      raise ConnectionError.new("Karma connection failed: #{ex.class}: #{ex.message}", host, port)
    end

    def close : Nil
      @socket.try(&.close)
    rescue IO::Error
    ensure
      @socket = nil
    end

    private def ensure_connected! : TCPSocket
      if socket = @socket
        return socket unless socket.closed?
      end

      connect_timeout = timeout_seconds(@connect_timeout)
      socket = TCPSocket.new(host, port, nil, connect_timeout)
      socket.read_timeout = @read_timeout if @read_timeout > Time::Span.zero
      socket.write_timeout = @write_timeout if @write_timeout > Time::Span.zero
      socket.tcp_nodelay = true if @tcp_nodelay
      @socket = socket
      socket
    rescue ex : IO::Error | Socket::Error
      close
      raise ConnectionError.new("Could not connect to Karma at #{host}:#{port}: #{ex.message}", host, port)
    end

    private def write_payload(socket : TCPSocket, payload : Hash(String, JSON::Any)) : Nil
      socket << payload.to_json << "\n"
      socket.flush
    rescue ex : IO::TimeoutError
      raise TimeoutError.new("write", @write_timeout, host, port)
    end

    private def read_response(socket : TCPSocket) : String
      line = socket.gets(chomp: true)
      raise ConnectionError.new("Karma closed the connection", host, port) unless line

      line
    rescue ex : IO::TimeoutError
      raise TimeoutError.new("read", @read_timeout, host, port)
    end

    private def timeout_seconds(timeout : Time::Span) : Float64?
      return nil if timeout <= Time::Span.zero

      timeout.total_seconds
    end
  end
end
