require "json"

module KarmaClient
  struct Response
    getter protocol_version : Int32?
    getter value : JSON::Any
    getter error_code : String?

    def self.parse(line : String) : Response
      parsed = JSON.parse(line)
      object = parsed.as_h
      success = object["success"]?.try(&.as_bool)
      raise ProtocolError.new("Invalid Karma response envelope: missing success", line) if success.nil?

      new(
        protocol_version: object["protocol_version"]?.try(&.as_i),
        success: success,
        value: object["response"]? || JSON::Any.new(nil),
        error_code: object["error_code"]?.try(&.as_s?),
        idempotent: object["idempotent"]?.try(&.as_bool?)
      )
    rescue ex : JSON::ParseException
      raise ProtocolError.new("Invalid Karma JSON response: #{ex.message}", line)
    rescue ex : TypeCastError
      raise ProtocolError.new("Karma response must be a JSON object with v2 envelope fields", line)
    end

    def initialize(@protocol_version : Int32?, @success : Bool, @value : JSON::Any, @error_code : String?, @idempotent : Bool? = nil)
    end

    def success? : Bool
      @success
    end

    def error? : Bool
      !success?
    end

    def idempotent? : Bool
      @idempotent == true
    end
  end
end
