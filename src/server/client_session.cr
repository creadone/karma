module Karma
  class ClientSession(Client)
    def initialize(@client : Client, @cluster : Cluster)
    end

    def run : Nil
      configure_timeouts

      while message = @client.gets('\n', Karma.config.max_request_bytes + 1, chomp: true)
        if message.bytesize > Karma.config.max_request_bytes
          write_line(Karma::Protocol.error("request_too_large", "Request exceeds #{Karma.config.max_request_bytes} bytes"))
          break
        end

        if answer = Commands.call(message, @cluster)
          write_line(answer)
        end
      end
    end

    private def configure_timeouts : Nil
      @client.read_timeout = Karma.config.read_timeout_seconds.seconds if Karma.config.read_timeout_seconds > 0
      @client.write_timeout = Karma.config.write_timeout_seconds.seconds if Karma.config.write_timeout_seconds > 0
    end

    private def write_line(message : String) : Nil
      @client << message << "\n"
      @client.flush
    end
  end
end
