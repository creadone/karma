require "json"

module Karma
  class Error < Exception
    getter code : String

    def initialize(@code : String, message : String)
      super(message)
    end
  end

  module Protocol
    VERSION = 1_u32

    def self.success(response) : String
      JSON.build do |json|
        json.object do
          json.field "protocol_version", VERSION
          json.field "success", true
          json.field "response" do
            response.to_json(json)
          end
          json.field "error_code", nil
        end
      end
    end

    def self.error(code : String, message : String) : String
      JSON.build do |json|
        json.object do
          json.field "protocol_version", VERSION
          json.field "success", false
          json.field "response", message
          json.field "error_code", code
        end
      end
    end
  end
end
