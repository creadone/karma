# frozen_string_literal: true

require "thread"

module KarmaClient
  class Pool
    def initialize(size:, timeout:, &factory)
      raise ConfigurationError, "pool size must be greater than 0" unless size.to_i.positive?
      raise ArgumentError, "factory block is required" unless factory

      @size = size.to_i
      @timeout = timeout.to_f
      @factory = factory
      @mutex = Mutex.new
      @condition = ConditionVariable.new
      @available = []
      @created = 0
      @closed = false
    end

    def with
      client = checkout
      yield client
    ensure
      checkin(client) if client
    end

    def close
      clients = nil
      @mutex.synchronize do
        @closed = true
        clients = @available
        @available = []
        @created -= clients.size
        @condition.broadcast
      end

      clients.each(&:close)
    end

    private

    def checkout
      create = false
      deadline = deadline_for(@timeout)

      @mutex.synchronize do
        loop do
          raise PoolTimeout, "Karma client pool is closed" if @closed

          return @available.pop unless @available.empty?

          if @created < @size
            @created += 1
            create = true
            break
          end

          remaining = remaining_seconds(deadline)
          if remaining && remaining <= 0
            raise PoolTimeout, "Timed out waiting for a Karma client connection"
          end

          @condition.wait(@mutex, remaining)
        end
      end

      @factory.call if create
    rescue StandardError
      @mutex.synchronize do
        @created -= 1 if create
        @condition.signal
      end
      raise
    end

    def checkin(client)
      close_client = false

      @mutex.synchronize do
        if @closed
          @created -= 1
          close_client = true
        else
          @available << client
          @condition.signal
        end
      end

      client.close if close_client
    end

    def deadline_for(timeout)
      return nil if timeout.zero?

      monotonic_seconds + timeout
    end

    def remaining_seconds(deadline)
      return nil if deadline.nil?

      deadline - monotonic_seconds
    end

    def monotonic_seconds
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
