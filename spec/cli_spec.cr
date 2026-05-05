require "./spec_helper"

CLI_ENV_KEYS = %w[
  KARMA_HOST
  KARMA_PORT
  KARMA_DUMP_DIR
  KARMA_RESTORE
  KARMA_TCP_NODELAY
  KARMA_WAL
  KARMA_WAL_FSYNC
  KARMA_MAX_REQUEST_BYTES
  KARMA_MAX_RESPONSE_BYTES
  KARMA_READ_TIMEOUT_SECONDS
  KARMA_WRITE_TIMEOUT_SECONDS
  KARMA_QUERY_TIMEOUT_MS
  KARMA_SHUTDOWN_TIMEOUT_SECONDS
  KARMA_DUMP_RETENTION_PER_TREE
  KARMA_AUTH_TOKEN
  KARMA_READ_AUTH_TOKEN
  KARMA_LOG
]

private def clear_cli_env : Nil
  CLI_ENV_KEYS.each { |key| ENV.delete(key) }
end

describe Karma::Cli do
  it "applies command line options when explicitly parsed" do
    clear_cli_env
    Karma.configure do |c|
      c.host = "0.0.0.0"
      c.port = 8080
      c.restore = true
      c.tcp_nodelay = true
      c.wal = true
      c.wal_fsync = true
      c.max_request_bytes = 4096
      c.max_response_bytes = 1_048_576
      c.read_timeout_seconds = 5
      c.write_timeout_seconds = 5
      c.query_timeout_ms = 1_000
      c.shutdown_timeout_seconds = 5
      c.dump_retention_per_tree = 5
      c.log = false
    end

    Karma::Cli.parse!([
      "--bind=127.0.0.1",
      "--port=9090",
      "--directory=/tmp/karma-test",
      "--restore=false",
      "--nodelay=false",
      "--wal=false",
      "--wal-fsync=false",
      "--max-request-bytes=8192",
      "--max-response-bytes=2048",
      "--read-timeout=3",
      "--write-timeout=4",
      "--query-timeout-ms=250",
      "--shutdown-timeout=6",
      "--dump-retention-per-tree=2",
      "--auth-token=write",
      "--read-auth-token=read",
      "--log=true",
    ])

    Karma.config.host.should eq("127.0.0.1")
    Karma.config.port.should eq(9090)
    Karma.config.dump_dir.should eq("/tmp/karma-test")
    Karma.config.restore.should be_false
    Karma.config.tcp_nodelay.should be_false
    Karma.config.wal.should be_false
    Karma.config.wal_fsync.should be_false
    Karma.config.max_request_bytes.should eq(8192)
    Karma.config.max_response_bytes.should eq(2048)
    Karma.config.read_timeout_seconds.should eq(3)
    Karma.config.write_timeout_seconds.should eq(4)
    Karma.config.query_timeout_ms.should eq(250)
    Karma.config.shutdown_timeout_seconds.should eq(6)
    Karma.config.dump_retention_per_tree.should eq(2)
    Karma.config.auth_token.should eq("write")
    Karma.config.read_auth_token.should eq("read")
    Karma.config.log.should be_true
  ensure
    Karma.configure do |c|
      c.host = "0.0.0.0"
      c.port = 8080
      c.dump_dir = "."
      c.restore = true
      c.tcp_nodelay = true
      c.wal = true
      c.wal_fsync = true
      c.max_request_bytes = 4096
      c.max_response_bytes = 1_048_576
      c.read_timeout_seconds = 5
      c.write_timeout_seconds = 5
      c.query_timeout_ms = 1_000
      c.shutdown_timeout_seconds = 5
      c.dump_retention_per_tree = 5
      c.auth_token = nil
      c.read_auth_token = nil
      c.log = false
    end
  end

  it "loads environment configuration before command line options" do
    clear_cli_env
    Karma.configure do |c|
      c.host = "0.0.0.0"
      c.port = 8080
      c.dump_dir = "."
      c.restore = true
      c.tcp_nodelay = true
      c.wal = true
      c.wal_fsync = true
      c.max_request_bytes = 4096
      c.max_response_bytes = 1_048_576
      c.read_timeout_seconds = 5
      c.write_timeout_seconds = 5
      c.query_timeout_ms = 1_000
      c.shutdown_timeout_seconds = 5
      c.dump_retention_per_tree = 5
      c.auth_token = nil
      c.read_auth_token = nil
      c.log = false
    end

    ENV["KARMA_HOST"] = "127.0.0.1"
    ENV["KARMA_PORT"] = "7000"
    ENV["KARMA_DUMP_DIR"] = "/var/lib/karma"
    ENV["KARMA_RESTORE"] = "false"
    ENV["KARMA_TCP_NODELAY"] = "false"
    ENV["KARMA_WAL"] = "false"
    ENV["KARMA_WAL_FSYNC"] = "false"
    ENV["KARMA_MAX_REQUEST_BYTES"] = "8192"
    ENV["KARMA_MAX_RESPONSE_BYTES"] = "16384"
    ENV["KARMA_READ_TIMEOUT_SECONDS"] = "8"
    ENV["KARMA_WRITE_TIMEOUT_SECONDS"] = "9"
    ENV["KARMA_QUERY_TIMEOUT_MS"] = "300"
    ENV["KARMA_SHUTDOWN_TIMEOUT_SECONDS"] = "11"
    ENV["KARMA_DUMP_RETENTION_PER_TREE"] = "7"
    ENV["KARMA_AUTH_TOKEN"] = "write-env"
    ENV["KARMA_READ_AUTH_TOKEN"] = "read-env"
    ENV["KARMA_LOG"] = "true"

    Karma::Cli.parse!(["--port=7001", "--wal=true"])

    Karma.config.host.should eq("127.0.0.1")
    Karma.config.port.should eq(7001)
    Karma.config.dump_dir.should eq("/var/lib/karma")
    Karma.config.restore.should be_false
    Karma.config.tcp_nodelay.should be_false
    Karma.config.wal.should be_true
    Karma.config.wal_fsync.should be_false
    Karma.config.max_request_bytes.should eq(8192)
    Karma.config.max_response_bytes.should eq(16_384)
    Karma.config.read_timeout_seconds.should eq(8)
    Karma.config.write_timeout_seconds.should eq(9)
    Karma.config.query_timeout_ms.should eq(300)
    Karma.config.shutdown_timeout_seconds.should eq(11)
    Karma.config.dump_retention_per_tree.should eq(7)
    Karma.config.auth_token.should eq("write-env")
    Karma.config.read_auth_token.should eq("read-env")
    Karma.config.log.should be_true
  ensure
    clear_cli_env
    Karma.configure do |c|
      c.host = "0.0.0.0"
      c.port = 8080
      c.dump_dir = "."
      c.restore = true
      c.tcp_nodelay = true
      c.wal = true
      c.wal_fsync = true
      c.max_request_bytes = 4096
      c.max_response_bytes = 1_048_576
      c.read_timeout_seconds = 5
      c.write_timeout_seconds = 5
      c.query_timeout_ms = 1_000
      c.shutdown_timeout_seconds = 5
      c.dump_retention_per_tree = 5
      c.auth_token = nil
      c.read_auth_token = nil
      c.log = false
    end
  end

  it "rejects invalid boolean command line flags" do
    clear_cli_env

    expect_raises(Karma::Error, "--wal must be true or false") do
      Karma::Cli.parse!(["--wal=maybe"])
    end
  end
end
