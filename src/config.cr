module Karma
  class Config
    INSTANCE = Config.new

    property host : String = "0.0.0.0"
    property port : Int32 = 8080
    property dump_dir : String = "."
    property restore : Bool = true
    property tcp_nodelay : Bool = true
    property wal : Bool = true
    property wal_fsync : Bool = true
    property max_request_bytes : Int32 = 4096
    property max_response_bytes : Int32 = 1_048_576
    property read_timeout_seconds : Int32 = 5
    property write_timeout_seconds : Int32 = 5
    property dump_retention_per_tree : Int32 = 5
    property auth_token : String?
    property read_auth_token : String?
    property log : Bool = true
  end

  def self.configure(&)
    yield Config::INSTANCE
  end

  def self.config
    Config::INSTANCE
  end
end
