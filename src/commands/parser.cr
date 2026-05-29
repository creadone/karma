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
      if object.has_key?("op") || object["v"]?.try(&.as_i?) == 2
        parse_v2(object)
      else
        Directive.from_json(message)
      end
    end
  end
end
