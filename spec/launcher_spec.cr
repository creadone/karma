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
end
