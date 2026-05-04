require "json"

module Karma
  module Log
    def self.info(event : String, message : String? = nil) : Nil
      write(STDOUT, "info", event, message)
    end

    def self.error(event : String, message : String? = nil) : Nil
      write(STDERR, "error", event, message)
    end

    private def self.write(io, level : String, event : String, message : String?) : Nil
      return unless Karma.config.log

      payload = JSON.build do |json|
        json.object do
          json.field "timestamp", Time.utc.to_rfc3339
          json.field "level", level
          json.field "event", event
          json.field "message", message unless message.nil?
        end
      end
      io.puts payload
    end
  end
end
