# frozen_string_literal: true

require "json"

module KarmaClient
  class Response
    attr_reader :protocol_version, :value, :error_code

    def self.parse(line)
      payload = JSON.parse(line)
      unless payload.is_a?(Hash)
        raise ProtocolError.new("Karma response must be a JSON object", payload: line)
      end

      new(
        protocol_version: payload["protocol_version"],
        success: payload.fetch("success"),
        value: payload["response"],
        error_code: payload["error_code"]
      )
    rescue JSON::ParserError => e
      raise ProtocolError.new("Invalid Karma JSON response: #{e.message}", payload: line)
    rescue KeyError => e
      raise ProtocolError.new("Invalid Karma response envelope: missing #{e.key}", payload: line)
    end

    def initialize(protocol_version:, success:, value:, error_code:)
      unless [true, false].include?(success)
        raise ProtocolError, "Invalid Karma response envelope: success must be boolean"
      end

      @protocol_version = protocol_version
      @success = success
      @value = value
      @error_code = error_code
    end

    def success?
      @success
    end

    def error?
      !success?
    end
  end
end
