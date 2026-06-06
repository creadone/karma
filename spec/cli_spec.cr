require "./spec_helper"

CLI_ENV_KEYS = %w[
  KARMA_HOST
  KARMA_PORT
  KARMA_DUMP_DIR
  KARMA_ROLE
  KARMA_RESTORE
  KARMA_TCP_NODELAY
  KARMA_WAL
  KARMA_WAL_FSYNC
  KARMA_WAL_SEGMENT_BYTES
  KARMA_WAL_BATCH_SIZE
  KARMA_WAL_BATCH_WAIT_MICROSECONDS
  KARMA_MAX_REQUEST_BYTES
  KARMA_MAX_RESPONSE_BYTES
  KARMA_READ_TIMEOUT_SECONDS
  KARMA_WRITE_TIMEOUT_SECONDS
  KARMA_QUERY_TIMEOUT_MS
  KARMA_SHUTDOWN_TIMEOUT_SECONDS
  KARMA_DUMP_RETENTION_PER_TREE
  KARMA_REPLICATION_SOURCE_HOST
  KARMA_REPLICATION_SOURCE_PORT
  KARMA_REPLICATION_TOKEN
  KARMA_REPLICATION_POLL_INTERVAL_MS
  KARMA_REPLICATION_BATCH_SIZE
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
      c.role = "master"
      c.restore = true
      c.tcp_nodelay = true
      c.wal = true
      c.wal_fsync = true
      c.wal_segment_bytes = 64 * 1024 * 1024
      c.wal_batch_size = 1_024
      c.wal_batch_wait_microseconds = 0
      c.max_request_bytes = 4096
      c.max_response_bytes = 1_048_576
      c.read_timeout_seconds = 5
      c.write_timeout_seconds = 5
      c.query_timeout_ms = 1_000
      c.shutdown_timeout_seconds = 5
      c.dump_retention_per_tree = 5
      c.replication_source_host = nil
      c.replication_source_port = 8080
      c.replication_token = nil
      c.replication_poll_interval_ms = 1_000
      c.replication_batch_size = 1_000
      c.log = false
    end

    Karma::Cli.parse!([
      "--bind=127.0.0.1",
      "--port=9090",
      "--directory=/tmp/karma-test",
      "--role=slave",
      "--restore=false",
      "--nodelay=false",
      "--wal=false",
      "--wal-fsync=false",
      "--wal-segment-bytes=123456",
      "--wal-batch-size=256",
      "--wal-batch-wait-us=50",
      "--max-request-bytes=8192",
      "--max-response-bytes=2048",
      "--read-timeout=3",
      "--write-timeout=4",
      "--query-timeout-ms=250",
      "--shutdown-timeout=6",
      "--dump-retention-per-tree=2",
      "--replication-source-host=127.0.0.2",
      "--replication-source-port=7070",
      "--replication-token=repl",
      "--replication-poll-interval-ms=25",
      "--replication-batch-size=500",
      "--auth-token=write",
      "--read-auth-token=read",
      "--log=true",
    ])

    Karma.config.host.should eq("127.0.0.1")
    Karma.config.port.should eq(9090)
    Karma.config.dump_dir.should eq("/tmp/karma-test")
    Karma.config.role.should eq("slave")
    Karma.config.restore.should be_false
    Karma.config.tcp_nodelay.should be_false
    Karma.config.wal.should be_false
    Karma.config.wal_fsync.should be_false
    Karma.config.wal_segment_bytes.should eq(123_456)
    Karma.config.wal_batch_size.should eq(256)
    Karma.config.wal_batch_wait_microseconds.should eq(50)
    Karma.config.max_request_bytes.should eq(8192)
    Karma.config.max_response_bytes.should eq(2048)
    Karma.config.read_timeout_seconds.should eq(3)
    Karma.config.write_timeout_seconds.should eq(4)
    Karma.config.query_timeout_ms.should eq(250)
    Karma.config.shutdown_timeout_seconds.should eq(6)
    Karma.config.dump_retention_per_tree.should eq(2)
    Karma.config.replication_source_host.should eq("127.0.0.2")
    Karma.config.replication_source_port.should eq(7070)
    Karma.config.replication_token.should eq("repl")
    Karma.config.replication_poll_interval_ms.should eq(25)
    Karma.config.replication_batch_size.should eq(500)
    Karma.config.auth_token.should eq("write")
    Karma.config.read_auth_token.should eq("read")
    Karma.config.log.should be_true
  ensure
    Karma.configure do |c|
      c.host = "0.0.0.0"
      c.port = 8080
      c.dump_dir = "."
      c.role = "master"
      c.restore = true
      c.tcp_nodelay = true
      c.wal = true
      c.wal_fsync = true
      c.wal_segment_bytes = 64 * 1024 * 1024
      c.wal_batch_size = 1_024
      c.wal_batch_wait_microseconds = 0
      c.max_request_bytes = 4096
      c.max_response_bytes = 1_048_576
      c.read_timeout_seconds = 5
      c.write_timeout_seconds = 5
      c.query_timeout_ms = 1_000
      c.shutdown_timeout_seconds = 5
      c.dump_retention_per_tree = 5
      c.replication_source_host = nil
      c.replication_source_port = 8080
      c.replication_token = nil
      c.replication_poll_interval_ms = 1_000
      c.replication_batch_size = 1_000
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
      c.role = "master"
      c.restore = true
      c.tcp_nodelay = true
      c.wal = true
      c.wal_fsync = true
      c.wal_segment_bytes = 64 * 1024 * 1024
      c.wal_batch_size = 1_024
      c.wal_batch_wait_microseconds = 0
      c.max_request_bytes = 4096
      c.max_response_bytes = 1_048_576
      c.read_timeout_seconds = 5
      c.write_timeout_seconds = 5
      c.query_timeout_ms = 1_000
      c.shutdown_timeout_seconds = 5
      c.dump_retention_per_tree = 5
      c.replication_source_host = nil
      c.replication_source_port = 8080
      c.replication_token = nil
      c.replication_poll_interval_ms = 1_000
      c.replication_batch_size = 1_000
      c.auth_token = nil
      c.read_auth_token = nil
      c.log = false
    end

    ENV["KARMA_HOST"] = "127.0.0.1"
    ENV["KARMA_PORT"] = "7000"
    ENV["KARMA_DUMP_DIR"] = "/var/lib/karma"
    ENV["KARMA_ROLE"] = "slave"
    ENV["KARMA_RESTORE"] = "false"
    ENV["KARMA_TCP_NODELAY"] = "false"
    ENV["KARMA_WAL"] = "false"
    ENV["KARMA_WAL_FSYNC"] = "false"
    ENV["KARMA_WAL_SEGMENT_BYTES"] = "654321"
    ENV["KARMA_WAL_BATCH_SIZE"] = "128"
    ENV["KARMA_WAL_BATCH_WAIT_MICROSECONDS"] = "25"
    ENV["KARMA_MAX_REQUEST_BYTES"] = "8192"
    ENV["KARMA_MAX_RESPONSE_BYTES"] = "16384"
    ENV["KARMA_READ_TIMEOUT_SECONDS"] = "8"
    ENV["KARMA_WRITE_TIMEOUT_SECONDS"] = "9"
    ENV["KARMA_QUERY_TIMEOUT_MS"] = "300"
    ENV["KARMA_SHUTDOWN_TIMEOUT_SECONDS"] = "11"
    ENV["KARMA_DUMP_RETENTION_PER_TREE"] = "7"
    ENV["KARMA_REPLICATION_SOURCE_HOST"] = "10.0.0.1"
    ENV["KARMA_REPLICATION_SOURCE_PORT"] = "7071"
    ENV["KARMA_REPLICATION_TOKEN"] = "repl-env"
    ENV["KARMA_REPLICATION_POLL_INTERVAL_MS"] = "50"
    ENV["KARMA_REPLICATION_BATCH_SIZE"] = "250"
    ENV["KARMA_AUTH_TOKEN"] = "write-env"
    ENV["KARMA_READ_AUTH_TOKEN"] = "read-env"
    ENV["KARMA_LOG"] = "true"

    Karma::Cli.parse!(["--port=7001", "--wal=true"])

    Karma.config.host.should eq("127.0.0.1")
    Karma.config.port.should eq(7001)
    Karma.config.dump_dir.should eq("/var/lib/karma")
    Karma.config.role.should eq("slave")
    Karma.config.restore.should be_false
    Karma.config.tcp_nodelay.should be_false
    Karma.config.wal.should be_true
    Karma.config.wal_fsync.should be_false
    Karma.config.wal_segment_bytes.should eq(654_321)
    Karma.config.wal_batch_size.should eq(128)
    Karma.config.wal_batch_wait_microseconds.should eq(25)
    Karma.config.max_request_bytes.should eq(8192)
    Karma.config.max_response_bytes.should eq(16_384)
    Karma.config.read_timeout_seconds.should eq(8)
    Karma.config.write_timeout_seconds.should eq(9)
    Karma.config.query_timeout_ms.should eq(300)
    Karma.config.shutdown_timeout_seconds.should eq(11)
    Karma.config.dump_retention_per_tree.should eq(7)
    Karma.config.replication_source_host.should eq("10.0.0.1")
    Karma.config.replication_source_port.should eq(7071)
    Karma.config.replication_token.should eq("repl-env")
    Karma.config.replication_poll_interval_ms.should eq(50)
    Karma.config.replication_batch_size.should eq(250)
    Karma.config.auth_token.should eq("write-env")
    Karma.config.read_auth_token.should eq("read-env")
    Karma.config.log.should be_true
  ensure
    clear_cli_env
    Karma.configure do |c|
      c.host = "0.0.0.0"
      c.port = 8080
      c.dump_dir = "."
      c.role = "master"
      c.restore = true
      c.tcp_nodelay = true
      c.wal = true
      c.wal_fsync = true
      c.wal_segment_bytes = 64 * 1024 * 1024
      c.wal_batch_size = 1_024
      c.wal_batch_wait_microseconds = 0
      c.max_request_bytes = 4096
      c.max_response_bytes = 1_048_576
      c.read_timeout_seconds = 5
      c.write_timeout_seconds = 5
      c.query_timeout_ms = 1_000
      c.shutdown_timeout_seconds = 5
      c.dump_retention_per_tree = 5
      c.replication_source_host = nil
      c.replication_source_port = 8080
      c.replication_token = nil
      c.replication_poll_interval_ms = 1_000
      c.replication_batch_size = 1_000
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

  it "rejects invalid integer command line flags" do
    clear_cli_env

    expect_raises(Karma::Error, "--port must be an integer") do
      Karma::Cli.parse!(["--port=abc"])
    end
  end

  it "validates final configuration after environment and command line options" do
    clear_cli_env

    expect_raises(Karma::Error, "Invalid configuration: port must be between 1 and 65535") do
      Karma::Cli.parse!(["--port=0"])
    end
  ensure
    Karma.configure do |c|
      c.host = "0.0.0.0"
      c.port = 8080
      c.dump_dir = "."
      c.role = "master"
      c.restore = true
      c.tcp_nodelay = true
      c.wal = true
      c.wal_fsync = true
      c.wal_segment_bytes = 64 * 1024 * 1024
      c.wal_batch_size = 1_024
      c.wal_batch_wait_microseconds = 0
      c.max_request_bytes = 4096
      c.max_response_bytes = 1_048_576
      c.read_timeout_seconds = 5
      c.write_timeout_seconds = 5
      c.query_timeout_ms = 1_000
      c.shutdown_timeout_seconds = 5
      c.dump_retention_per_tree = 5
      c.replication_source_host = nil
      c.replication_source_port = 8080
      c.replication_token = nil
      c.replication_poll_interval_ms = 1_000
      c.replication_batch_size = 1_000
      c.auth_token = nil
      c.read_auth_token = nil
      c.log = false
    end
  end

  it "validates WAL segment size" do
    clear_cli_env

    expect_raises(Karma::Error, "Invalid configuration: wal_segment_bytes must be greater than or equal to 0") do
      Karma::Cli.parse!(["--wal-segment-bytes=-1"])
    end
  ensure
    Karma.configure { |c| c.wal_segment_bytes = 64 * 1024 * 1024 }
  end

  it "validates replication role" do
    clear_cli_env

    expect_raises(Karma::Error, "Invalid configuration: role must be master or slave") do
      Karma::Cli.parse!(["--role=replica"])
    end
  ensure
    Karma.configure { |c| c.role = "master" }
  end
end
