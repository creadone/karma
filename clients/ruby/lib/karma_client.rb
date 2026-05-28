# frozen_string_literal: true

require_relative "karma_client/version"
require_relative "karma_client/errors"
require_relative "karma_client/configuration"
require_relative "karma_client/response"
require_relative "karma_client/connection"
require_relative "karma_client/pool"
require_relative "karma_client/client"
require_relative "karma_client/railtie" if defined?(Rails::Railtie)

module KarmaClient
  class << self
    def configuration
      @configuration ||= Configuration.from_env
    end

    def configure
      yield configuration
      close
      configuration.validate!
      configuration
    end

    def with_client(&block)
      pool.with(&block)
    end

    def client
      Client.new(configuration)
    end

    def pool
      @pool_mutex ||= Mutex.new
      @pool_mutex.synchronize do
        @pool ||= Pool.new(size: configuration.pool_size, timeout: configuration.pool_timeout) do
          Client.new(configuration)
        end
      end
    end

    def close
      @pool_mutex ||= Mutex.new
      @pool_mutex.synchronize do
        @pool&.close
        @pool = nil
      end
    end
  end
end
