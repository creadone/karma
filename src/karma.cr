require "socket"
require "counter_tree"

require "./version"
require "./config"
require "./cluster"
require "./server"
require "./backup"
require "./cli"
require "./signal"
require "./command"
require "./launcher"

module Karma
  LAUNCHER = Launcher.new
  if PROGRAM_NAME == __FILE__
    LAUNCHER.run!
  end
end