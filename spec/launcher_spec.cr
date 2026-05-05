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
end
