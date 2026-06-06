require "json"

module Karma
  module Protocol
    VERSION = 2_u32

    def self.success(response, version = VERSION, idempotent : Bool? = nil) : String
      JSON.build do |json|
        json.object do
          json.field "protocol_version", version
          json.field "success", true
          json.field "response" do
            response.to_json(json)
          end
          json.field "idempotent", idempotent unless idempotent.nil?
          json.field "error_code", nil
        end
      end
    end

    def self.success_uint64(response : UInt64, version = VERSION) : String
      String.build do |io|
        io << %({"protocol_version":)
        io << version
        io << %(,"success":true,"response":)
        io << response
        io << %(,"error_code":null})
      end
    end

    def self.error(code : String, message : String, version = VERSION) : String
      JSON.build do |json|
        json.object do
          json.field "protocol_version", version
          json.field "success", false
          json.field "response", message
          json.field "error_code", code
        end
      end
    end
  end
end
