require "./spec_helper"

describe Karma::Launcher do
  it "ignores dump requests before runtime is started" do
    launcher = Karma::Launcher.new

    launcher.dump_all
  end

  it "allows shutdown before runtime is started" do
    launcher = Karma::Launcher.new

    launcher.shutdown!
  end

  it "validates configuration before building runtime" do
    Karma.configure { |c| c.port = 0 }

    expect_raises(Karma::Error, "Invalid configuration: port must be between 1 and 65535") do
      Karma::Runtime.build
    end
  ensure
    Karma.configure { |c| c.port = 8080 }
  end

  it "builds replication poller for slave with a source" do
    Karma.configure do |c|
      c.role = "slave"
      c.replication_source_host = "127.0.0.1"
      c.replication_source_port = 7070
    end

    poller = Karma::Replication::Poller.build?(Karma::Cluster.new)

    poller.should_not be_nil
    poller.not_nil!.host.should eq("127.0.0.1")
    poller.not_nil!.port.should eq(7070)
  ensure
    Karma.configure do |c|
      c.role = "master"
      c.replication_source_host = nil
    end
  end
end
