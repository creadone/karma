module KarmaClient
  class Error < Exception
  end

  class ConfigurationError < Error
  end

  class InputError < Error
  end

  class PoolTimeout < Error
  end

  class TransportError < Error
    getter host : String?
    getter port : Int32?

    def initialize(message : String, @host : String? = nil, @port : Int32? = nil)
      super(message)
    end
  end

  class ConnectionError < TransportError
  end

  class TimeoutError < TransportError
    getter operation : String
    getter timeout : Time::Span

    def initialize(@operation : String, @timeout : Time::Span, host : String? = nil, port : Int32? = nil)
      super("Karma #{operation} timed out after #{timeout.total_seconds}s", host, port)
    end
  end

  class ProtocolError < Error
    getter payload : String?

    def initialize(message : String, @payload : String? = nil)
      super(message)
    end
  end

  class ServerError < Error
    RETRIABLE_CODES = Set{
      "query_timeout",
      "replication_gap",
      "replication_error",
      "internal_error",
    }

    getter code : String
    getter protocol_version : Int32?
    getter response : Response?

    def self.from_response(response : Response) : ServerError
      klass = case response.error_code
              when "validation_error"     then ValidationError
              when "not_found"            then NotFoundError
              when "unauthorized"         then UnauthorizedError
              when "forbidden"            then ForbiddenError
              when "request_too_large"    then RequestTooLargeError
              when "response_too_large"   then ResponseTooLargeError
              when "query_timeout"        then QueryTimeoutError
              when "idempotency_conflict" then IdempotencyConflictError
              else
                ServerError
              end

      klass.new(
        code: response.error_code || "server_error",
        message: response.value.to_s,
        protocol_version: response.protocol_version,
        response: response
      )
    end

    def initialize(@code : String, message : String, @protocol_version : Int32? = nil, @response : Response? = nil)
      super(message)
    end

    def retriable? : Bool
      RETRIABLE_CODES.includes?(code)
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

  class IdempotencyConflictError < ServerError
  end
end
