require "json"

module Karma
  module Commands
    def self.parse(message : String) : Directive
      payload = JSON.parse(message)
      object = payload.as_h

      if object.has_key?("op") || object["v"]?.try(&.as_i?) == 2
        parse_v2(object)
      else
        Directive.from_json(message)
      end
    rescue e : KeyError | TypeCastError
      raise Karma::Error.new("validation_error", e.message || "Invalid request")
    end
  end
end
