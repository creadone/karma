# frozen_string_literal: true

require "uri"

module KarmaClient
  class Configuration
    DEFAULT_HOST = "127.0.0.1"
    DEFAULT_PORT = 8080
    DEFAULT_CONNECT_TIMEOUT = 1.0
    DEFAULT_READ_TIMEOUT = 1.0
    DEFAULT_WRITE_TIMEOUT = 1.0
    DEFAULT_POOL_TIMEOUT = 1.0
    DEFAULT_POOL_SIZE = 5

    attr_accessor :host,
                  :port,
                  :token,
                  :connect_timeout,
                  :read_timeout,
                  :write_timeout,
                  :pool_size,
                  :pool_timeout,
                  :tcp_nodelay,
                  :instrumenter,
                  :logger

    def self.from_env(env = ENV)
      new.tap do |config|
        config.url = env["KARMA_URL"] if present?(env["KARMA_URL"])
        config.host = env["KARMA_HOST"] if present?(env["KARMA_HOST"])
        config.port = integer_env(env, "KARMA_PORT", config.port)
        token = first_present(env["KARMA_TOKEN"], env["KARMA_AUTH_TOKEN"], env["KARMA_READ_AUTH_TOKEN"])
        config.token = token if present?(token)
        config.connect_timeout = float_env(env, "KARMA_CONNECT_TIMEOUT", config.connect_timeout)
        config.read_timeout = float_env(env, "KARMA_READ_TIMEOUT", config.read_timeout)
        config.write_timeout = float_env(env, "KARMA_WRITE_TIMEOUT", config.write_timeout)
        config.pool_size = integer_env(env, "KARMA_POOL_SIZE", integer_env(env, "RAILS_MAX_THREADS", config.pool_size))
        config.pool_timeout = float_env(env, "KARMA_POOL_TIMEOUT", config.pool_timeout)
      end
    end

    def initialize
      @host = DEFAULT_HOST
      @port = DEFAULT_PORT
      @token = nil
      @connect_timeout = DEFAULT_CONNECT_TIMEOUT
      @read_timeout = DEFAULT_READ_TIMEOUT
      @write_timeout = DEFAULT_WRITE_TIMEOUT
      @pool_size = DEFAULT_POOL_SIZE
      @pool_timeout = DEFAULT_POOL_TIMEOUT
      @tcp_nodelay = true
      @instrumenter = nil
      @logger = nil
    end

    def url=(value)
      uri = URI.parse(value.to_s)
      unless uri.scheme == "tcp"
        raise ConfigurationError, "KARMA_URL must use tcp://host:port"
      end

      self.host = uri.host
      self.port = uri.port || DEFAULT_PORT

      query = URI.decode_www_form(uri.query.to_s).to_h
      self.token = query["token"] if self.class.present?(query["token"])
    rescue URI::InvalidURIError => e
      raise ConfigurationError, "Invalid KARMA_URL: #{e.message}"
    end

    def validate!
      raise ConfigurationError, "Karma host is required" unless self.class.present?(host)
      raise ConfigurationError, "Karma port must be greater than 0" unless port.to_i.positive?
      raise ConfigurationError, "connect_timeout must be greater than or equal to 0" if connect_timeout.to_f.negative?
      raise ConfigurationError, "read_timeout must be greater than or equal to 0" if read_timeout.to_f.negative?
      raise ConfigurationError, "write_timeout must be greater than or equal to 0" if write_timeout.to_f.negative?
      raise ConfigurationError, "pool_size must be greater than 0" unless pool_size.to_i.positive?
      raise ConfigurationError, "pool_timeout must be greater than or equal to 0" if pool_timeout.to_f.negative?
    end

    def to_connection_options
      validate!

      {
        host: host,
        port: port.to_i,
        connect_timeout: connect_timeout.to_f,
        read_timeout: read_timeout.to_f,
        write_timeout: write_timeout.to_f,
        tcp_nodelay: tcp_nodelay
      }
    end

    def self.present?(value)
      !value.nil? && !value.to_s.empty?
    end

    def self.first_present(*values)
      values.find { |value| present?(value) }
    end

    def self.integer_env(env, key, fallback)
      return fallback unless present?(env[key])

      Integer(env[key], 10)
    rescue ArgumentError
      raise ConfigurationError, "#{key} must be an integer"
    end

    def self.float_env(env, key, fallback)
      return fallback unless present?(env[key])

      Float(env[key])
    rescue ArgumentError
      raise ConfigurationError, "#{key} must be a number"
    end
  end
end
