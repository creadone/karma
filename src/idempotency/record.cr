require "json"

module Karma
  module Idempotency
    struct Record
      include JSON::Serializable

      getter key : String
      getter operation : String
      getter fingerprint : String
      getter response : JSON::Any
      getter created_at_unix : Int64

      def initialize(@key : String, @operation : String, @fingerprint : String, @response : JSON::Any, @created_at_unix : Int64)
      end

      def same_fingerprint?(other : String) : Bool
        fingerprint == other
      end
    end

    struct Result
      getter value : JSON::Any
      getter idempotent : Bool

      def initialize(@value : JSON::Any, @idempotent : Bool)
      end
    end
  end
end
