require "uri"
require "uri/params"

module KarmaClient
  class Configuration
    DEFAULT_HOST            = "127.0.0.1"
    DEFAULT_PORT            = 8080
    DEFAULT_CONNECT_TIMEOUT = 1.0.seconds
    DEFAULT_READ_TIMEOUT    = 1.0.seconds
    DEFAULT_WRITE_TIMEOUT   = 1.0.seconds
    DEFAULT_POOL_TIMEOUT    = 1.0.seconds
    DEFAULT_POOL_SIZE       = 5

    property host : String
    property port : Int32
    property token : String?
    property connect_timeout : Time::Span
    property read_timeout : Time::Span
    property write_timeout : Time::Span
    property pool_size : Int32
    property pool_timeout : Time::Span
    property tcp_nodelay : Bool

    def self.from_env(env = ENV) : Configuration
      new.tap do |config|
        if url = present_value(env["KARMA_URL"]?)
          config.url = url
        end

        if host = present_value(env["KARMA_HOST"]?)
          config.host = host
        end
        config.port = integer_env(env, "KARMA_PORT", config.port)

        token = first_present(env["KARMA_TOKEN"]?, env["KARMA_AUTH_TOKEN"]?, env["KARMA_READ_AUTH_TOKEN"]?)
        if token
          config.token = token
        end

        config.connect_timeout = seconds_env(env, "KARMA_CONNECT_TIMEOUT", config.connect_timeout)
        config.read_timeout = seconds_env(env, "KARMA_READ_TIMEOUT", config.read_timeout)
        config.write_timeout = seconds_env(env, "KARMA_WRITE_TIMEOUT", config.write_timeout)
        config.pool_size = integer_env(env, "KARMA_POOL_SIZE", integer_env(env, "RAILS_MAX_THREADS", config.pool_size))
        config.pool_timeout = seconds_env(env, "KARMA_POOL_TIMEOUT", config.pool_timeout)
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
    end

    def copy : Configuration
      copied = Configuration.new
      copied.host = host
      copied.port = port
      copied.token = token
      copied.connect_timeout = connect_timeout
      copied.read_timeout = read_timeout
      copied.write_timeout = write_timeout
      copied.pool_size = pool_size
      copied.pool_timeout = pool_timeout
      copied.tcp_nodelay = tcp_nodelay
      copied
    end

    def url=(value : String)
      uri = URI.parse(value)
      raise ConfigurationError.new("KARMA_URL must use tcp://host:port") unless uri.scheme == "tcp"

      self.host = uri.host || raise ConfigurationError.new("KARMA_URL host is required")
      self.port = uri.port || DEFAULT_PORT

      if query = uri.query
        params = URI::Params.parse(query)
        if token = self.class.present_value(params["token"]?)
          self.token = token
        end
      end
    rescue ex : URI::Error
      raise ConfigurationError.new("Invalid KARMA_URL: #{ex.message}")
    end

    def validate! : Nil
      raise ConfigurationError.new("Karma host is required") unless self.class.present?(host)
      raise ConfigurationError.new("Karma port must be greater than 0") unless port > 0
      raise ConfigurationError.new("connect_timeout must be greater than or equal to 0") if connect_timeout < Time::Span.zero
      raise ConfigurationError.new("read_timeout must be greater than or equal to 0") if read_timeout < Time::Span.zero
      raise ConfigurationError.new("write_timeout must be greater than or equal to 0") if write_timeout < Time::Span.zero
      raise ConfigurationError.new("pool_size must be greater than 0") unless pool_size > 0
      raise ConfigurationError.new("pool_timeout must be greater than or equal to 0") if pool_timeout < Time::Span.zero
    end

    def self.present?(value) : Bool
      !value.nil? && !value.to_s.empty?
    end

    def self.present_value(value) : String?
      return nil unless present?(value)

      value.to_s
    end

    private def self.first_present(*values) : String?
      values.each do |value|
        return value.to_s if present?(value)
      end

      nil
    end

    private def self.integer_env(env, key : String, fallback : Int32) : Int32
      value = present_value(env[key]?)
      return fallback unless value

      value.to_i
    rescue ArgumentError
      raise ConfigurationError.new("#{key} must be an integer")
    end

    private def self.seconds_env(env, key : String, fallback : Time::Span) : Time::Span
      value = present_value(env[key]?)
      return fallback unless value

      value.to_f.seconds
    rescue ArgumentError
      raise ConfigurationError.new("#{key} must be a number")
    end
  end
end
