module Karma
  class Error < Exception
    getter code : String

    def initialize(@code : String, message : String)
      super(message)
    end
  end
end
