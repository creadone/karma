# frozen_string_literal: true

module KarmaClient
  class Error < StandardError
  end

  class ConfigurationError < Error
  end

  class InputError < Error
  end

  class PoolTimeout < Error
  end

  class TransportError < Error
    attr_reader :host, :port

    def initialize(message, host: nil, port: nil)
      @host = host
      @port = port
      super(message)
    end
  end

  class ConnectionError < TransportError
  end

  class TimeoutError < TransportError
    attr_reader :operation, :timeout

    def initialize(operation:, timeout:, host: nil, port: nil)
      @operation = operation
      @timeout = timeout
      super("Karma #{operation} timed out after #{timeout}s", host: host, port: port)
    end
  end

  class ProtocolError < Error
    attr_reader :payload

    def initialize(message, payload: nil)
      @payload = payload
      super(message)
    end
  end

  class ServerError < Error
    RETRIABLE_CODES = %w[
      query_timeout
      replication_gap
      replication_error
      internal_error
    ].freeze

    attr_reader :code, :protocol_version, :response

    def self.from_response(response)
      klass = case response.error_code
              when "validation_error" then ValidationError
              when "not_found" then NotFoundError
              when "unauthorized" then UnauthorizedError
              when "forbidden" then ForbiddenError
              when "request_too_large" then RequestTooLargeError
              when "response_too_large" then ResponseTooLargeError
              when "query_timeout" then QueryTimeoutError
              else ServerError
              end

      klass.new(
        code: response.error_code || "server_error",
        message: response.value.to_s,
        protocol_version: response.protocol_version,
        response: response
      )
    end

    def initialize(code:, message:, protocol_version: nil, response: nil)
      @code = code
      @protocol_version = protocol_version
      @response = response
      super(message)
    end

    def retriable?
      RETRIABLE_CODES.include?(code)
    end
  end

  class ValidationError < ServerError
  end

  class NotFoundError < ServerError
  end

  class UnauthorizedError < ServerError
  end

  class ForbiddenError < ServerError
  end

  class RequestTooLargeError < ServerError
  end

  class ResponseTooLargeError < ServerError
  end

  class QueryTimeoutError < ServerError
  end
end
