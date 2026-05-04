module Karma
  module State
    MUTEX = Mutex.new

    def self.synchronize(&)
      MUTEX.synchronize do
        yield
      end
    end
  end
end
