require "./karma_client/version"
require "./karma_client/errors"
require "./karma_client/configuration"
require "./karma_client/response"
require "./karma_client/connection"
require "./karma_client/pool"
require "./karma_client/client"

module KarmaClient
  @@configuration : Configuration?
  @@pool : Pool?
  @@mutex = Mutex.new

  def self.configuration : Configuration
    @@configuration ||= Configuration.from_env
  end

  def self.configure(&) : Configuration
    config = configuration
    yield config
    close
    config.validate!
    config
  end

  def self.client : Client
    Client.new(configuration.copy)
  end

  def self.with_client(&)
    pool.with do |client|
      yield client
    end
  end

  def self.pool : Pool
    @@mutex.synchronize do
      @@pool ||= Pool.new(size: configuration.pool_size, timeout: configuration.pool_timeout) do
        Client.new(configuration.copy)
      end
    end
  end

  def self.close : Nil
    @@mutex.synchronize do
      @@pool.try(&.close)
      @@pool = nil
    end
  end
end
