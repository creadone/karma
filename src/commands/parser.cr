require "json"

module Karma
  module Commands
    def self.parse(message : String) : Directive
      payload = JSON.parse(message)
      object = payload.as_h
      parse_object(message, object)
    rescue e : KeyError | TypeCastError
      raise Karma::Error.new("validation_error", e.message || "Invalid request")
    end

    private def self.parse_object(message : String, object : Hash(String, JSON::Any)) : Directive
      require_v2_request!(object)
      parse_v2(object)
    end

    private def self.require_v2_request!(object : Hash(String, JSON::Any)) : Nil
      version = object["v"]?.try(&.as_i?)
      raise Karma::Error.new("unsupported_protocol", "Karma 1.0 accepts only protocol v2 requests with field v=2") unless version == 2
      raise Karma::Error.new("validation_error", "Field op is required") unless object["op"]?.try(&.as_s?)
    end
  end
end
