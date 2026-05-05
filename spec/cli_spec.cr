require "./spec_helper"

describe Karma::Cli do
  it "applies command line options when explicitly parsed" do
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
      c.dump_retention_per_tree = 5
      c.auth_token = nil
      c.read_auth_token = nil
      c.log = false
    end
  end
end
