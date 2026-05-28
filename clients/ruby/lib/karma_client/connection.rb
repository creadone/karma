# frozen_string_literal: true

require "json"
require "socket"

module KarmaClient
  class Connection
    READ_CHUNK_BYTES = 16 * 1024

    attr_reader :host, :port

    def initialize(host:, port:, connect_timeout:, read_timeout:, write_timeout:, tcp_nodelay: true)
      @host = host
      @port = port
      @connect_timeout = connect_timeout
      @read_timeout = read_timeout
      @write_timeout = write_timeout
      @tcp_nodelay = tcp_nodelay
      @socket = nil
      @read_buffer = +""
    end

    def request(payload)
      ensure_connected!
      write_all(JSON.generate(payload) + "\n")
      read_line
    rescue TimeoutError
      close
      raise
    rescue IOError, SystemCallError, SocketError => e
      close
      raise ConnectionError.new("Karma connection failed: #{e.class}: #{e.message}", host: host, port: port)
    end

    def close
      @socket&.close
    rescue IOError
      nil
    ensure
      @socket = nil
      @read_buffer = +""
    end

    private

    def ensure_connected!
      return if @socket && !@socket.closed?

      connect_timeout = timeout_value(@connect_timeout)
      @socket = if connect_timeout.zero?
                  Socket.tcp(host, port)
                else
                  Socket.tcp(host, port, connect_timeout: connect_timeout)
                end
      @socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1) if @tcp_nodelay
      @read_buffer = +""
    rescue IOError, SystemCallError, SocketError => e
      close
      raise ConnectionError.new("Could not connect to Karma at #{host}:#{port}: #{e.message}", host: host, port: port)
    end

    def write_all(data)
      deadline = deadline_for(@write_timeout)
      written = 0

      while written < data.bytesize
        wait_writable(deadline)
        chunk = data.byteslice(written, data.bytesize - written)
        result = @socket.write_nonblock(chunk, exception: false)

        if result == :wait_writable
          next
        end

        written += result
      end
    end

    def read_line
      loop do
        if (index = @read_buffer.index("\n"))
          line = @read_buffer.slice!(0, index + 1)
          return line.strip
        end

        wait_readable(deadline ||= deadline_for(@read_timeout))
        chunk = @socket.read_nonblock(READ_CHUNK_BYTES, exception: false)

        case chunk
        when :wait_readable
          next
        when nil
          raise ConnectionError.new("Karma closed the connection", host: host, port: port)
        else
          @read_buffer << chunk
        end
      end
    rescue EOFError
      raise ConnectionError.new("Karma closed the connection", host: host, port: port)
    end

    def wait_readable(deadline)
      wait_for_io(:read, deadline, @read_timeout) { IO.select([@socket], nil, nil, remaining_seconds(deadline)) }
    end

    def wait_writable(deadline)
      wait_for_io(:write, deadline, @write_timeout) { IO.select(nil, [@socket], nil, remaining_seconds(deadline)) }
    end

    def wait_for_io(operation, deadline, configured_timeout)
      return if yield

      raise TimeoutError.new(operation: operation, timeout: timeout_value(configured_timeout), host: host, port: port)
    end

    def deadline_for(timeout)
      return nil if timeout_value(timeout).zero?

      monotonic_seconds + timeout_value(timeout)
    end

    def remaining_seconds(deadline)
      return nil if deadline.nil?

      remaining = deadline - monotonic_seconds
      return 0 if remaining.negative?

      remaining
    end

    def timeout_value(timeout)
      timeout.to_f
    end

    def monotonic_seconds
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
