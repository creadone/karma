module Karma
  module State
    GATE_MUTEX = Mutex.new
    @@exclusive = false
    @@waiting_writers = 0
    @@active_readers = 0
    @@series_locks = {} of String => Mutex
    @@registry_mutex = Mutex.new

    def self.synchronize(&)
      enter_exclusive
      begin
        yield
      ensure
        exit_exclusive
      end
    end

    def self.synchronize_series(series : String, &)
      enter_shared
      lock = series_lock(series)
      begin
        lock.synchronize do
          yield
        end
      ensure
        exit_shared
      end
    end

    def self.synchronize_registry(&)
      @@registry_mutex.synchronize do
        yield
      end
    end

    private def self.series_lock(series : String) : Mutex
      GATE_MUTEX.synchronize do
        @@series_locks[series] ||= Mutex.new
      end
    end

    private def self.enter_exclusive : Nil
      GATE_MUTEX.synchronize do
        @@waiting_writers += 1
      end

      loop do
        acquired = false
        GATE_MUTEX.synchronize do
          if !@@exclusive && @@active_readers == 0
            @@waiting_writers -= 1
            @@exclusive = true
            acquired = true
          end
        end
        return if acquired

        sleep 1.millisecond
      end
    end

    private def self.exit_exclusive : Nil
      GATE_MUTEX.synchronize do
        @@exclusive = false
      end
    end

    private def self.enter_shared : Nil
      loop do
        acquired = false
        GATE_MUTEX.synchronize do
          if !@@exclusive && @@waiting_writers == 0
            @@active_readers += 1
            acquired = true
          end
        end
        return if acquired

        sleep 1.millisecond
      end
    end

    private def self.exit_shared : Nil
      GATE_MUTEX.synchronize do
        @@active_readers -= 1
      end
    end
  end
end
