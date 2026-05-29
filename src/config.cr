module Karma
  class Config
    INSTANCE = Config.new

    property host : String = "0.0.0.0"
    property port : Int32 = 8080
    property dump_dir : String = "."
    property role : String = "master"
    property restore : Bool = true
    property tcp_nodelay : Bool = true
    property wal : Bool = true
    property wal_fsync : Bool = true
    property max_request_bytes : Int32 = 4096
    property max_response_bytes : Int32 = 1_048_576
    property read_timeout_seconds : Int32 = 5
    property write_timeout_seconds : Int32 = 5
    property query_timeout_ms : Int32 = 1_000
    property shutdown_timeout_seconds : Int32 = 5
    property dump_retention_per_tree : Int32 = 5
    property replication_source_host : String?
    property replication_source_port : Int32 = 8080
    property replication_token : String?
    property replication_poll_interval_ms : Int32 = 1_000
    property replication_batch_size : Int32 = 1_000
    property auth_token : String?
    property read_auth_token : String?
    property idempotency_max_records : Int32 = 1_000_000
    property idempotency_max_age_seconds : Int32 = 604_800
    property log : Bool = true

    def load_env! : Nil
      @host = string_env("KARMA_HOST", @host)
      @port = int_env("KARMA_PORT", @port)
      @dump_dir = string_env("KARMA_DUMP_DIR", @dump_dir)
      @role = string_env("KARMA_ROLE", @role)
      @restore = bool_env("KARMA_RESTORE", @restore)
      @tcp_nodelay = bool_env("KARMA_TCP_NODELAY", @tcp_nodelay)
      @wal = bool_env("KARMA_WAL", @wal)
      @wal_fsync = bool_env("KARMA_WAL_FSYNC", @wal_fsync)
      @max_request_bytes = int_env("KARMA_MAX_REQUEST_BYTES", @max_request_bytes)
      @max_response_bytes = int_env("KARMA_MAX_RESPONSE_BYTES", @max_response_bytes)
      @read_timeout_seconds = int_env("KARMA_READ_TIMEOUT_SECONDS", @read_timeout_seconds)
      @write_timeout_seconds = int_env("KARMA_WRITE_TIMEOUT_SECONDS", @write_timeout_seconds)
      @query_timeout_ms = int_env("KARMA_QUERY_TIMEOUT_MS", @query_timeout_ms)
      @shutdown_timeout_seconds = int_env("KARMA_SHUTDOWN_TIMEOUT_SECONDS", @shutdown_timeout_seconds)
      @dump_retention_per_tree = int_env("KARMA_DUMP_RETENTION_PER_TREE", @dump_retention_per_tree)
      @replication_source_host = optional_string_env("KARMA_REPLICATION_SOURCE_HOST", @replication_source_host)
      @replication_source_port = int_env("KARMA_REPLICATION_SOURCE_PORT", @replication_source_port)
      @replication_token = optional_string_env("KARMA_REPLICATION_TOKEN", @replication_token)
      @replication_poll_interval_ms = int_env("KARMA_REPLICATION_POLL_INTERVAL_MS", @replication_poll_interval_ms)
      @replication_batch_size = int_env("KARMA_REPLICATION_BATCH_SIZE", @replication_batch_size)
      @auth_token = optional_string_env("KARMA_AUTH_TOKEN", @auth_token)
      @read_auth_token = optional_string_env("KARMA_READ_AUTH_TOKEN", @read_auth_token)
      @idempotency_max_records = int_env("KARMA_IDEMPOTENCY_MAX_RECORDS", @idempotency_max_records)
      @idempotency_max_age_seconds = int_env("KARMA_IDEMPOTENCY_MAX_AGE_SECONDS", @idempotency_max_age_seconds)
      @log = bool_env("KARMA_LOG", @log)
    end

    def validate! : Nil
      raise_validation("host must not be empty") if @host.empty?
      raise_validation("port must be between 1 and 65535") unless (1..65_535).includes?(@port)
      raise_validation("dump_dir must not be empty") if @dump_dir.empty?
      raise_validation("role must be master or slave") unless %w[master slave].includes?(@role)
      raise_validation("max_request_bytes must be greater than 0") unless @max_request_bytes > 0
      raise_validation("max_response_bytes must be greater than or equal to 0") unless @max_response_bytes >= 0
      raise_validation("read_timeout_seconds must be greater than or equal to 0") unless @read_timeout_seconds >= 0
      raise_validation("write_timeout_seconds must be greater than or equal to 0") unless @write_timeout_seconds >= 0
      raise_validation("query_timeout_ms must be greater than or equal to 0") unless @query_timeout_ms >= 0
      raise_validation("shutdown_timeout_seconds must be greater than or equal to 0") unless @shutdown_timeout_seconds >= 0
      raise_validation("dump_retention_per_tree must be greater than or equal to 0") unless @dump_retention_per_tree >= 0
      raise_validation("idempotency_max_records must be greater than 0") unless @idempotency_max_records > 0
      raise_validation("idempotency_max_age_seconds must be greater than or equal to 0") unless @idempotency_max_age_seconds >= 0
      validate_replication!
    end

    private def validate_replication! : Nil
      return unless source_host = @replication_source_host

      raise_validation("replication_source_host must not be empty") if source_host.empty?
      raise_validation("replication source requires slave role") unless @role == "slave"
      raise_validation("replication_source_port must be between 1 and 65535") unless (1..65_535).includes?(@replication_source_port)
      raise_validation("replication_poll_interval_ms must be greater than 0") unless @replication_poll_interval_ms > 0
      raise_validation("replication_batch_size must be between 1 and 10000") unless (1..10_000).includes?(@replication_batch_size)
    end

    private def string_env(name : String, fallback : String) : String
      ENV[name]? || fallback
    end

    private def optional_string_env(name : String, fallback : String?) : String?
      return fallback unless value = ENV[name]?
      return nil if value.empty?

      value
    end

    private def int_env(name : String, fallback : Int32) : Int32
      return fallback unless value = ENV[name]?

      value.to_i32
    rescue ArgumentError
      raise Karma::Error.new("validation_error", "Environment variable #{name} must be an integer")
    end

    private def bool_env(name : String, fallback : Bool) : Bool
      return fallback unless value = ENV[name]?

      case value
      when "true"
        true
      when "false"
        false
      else
        raise Karma::Error.new("validation_error", "Environment variable #{name} must be true or false")
      end
    end

    private def raise_validation(message : String) : NoReturn
      raise Karma::Error.new("validation_error", "Invalid configuration: #{message}")
    end
  end

  def self.configure(&)
    yield Config::INSTANCE
  end

  def self.config
    Config::INSTANCE
  end
end
