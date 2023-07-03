module Karma
  class Launcher
    def initialize
      @cluster = uninitialized Karma::Cluster
      @server  = uninitialized Karma::Server
    end

    def run!
      if Karma.config.restore
        @cluster = Cluster.restore(Karma.config.dump_dir)
      else
        @cluster = Cluster.new
      end
      @server = Karma::Server.new(@cluster)
      STDOUT.puts "Karma v.#{Karma::VERSION} is on #{Karma.config.port}."
      @server.start!
    end

    def dump_all
      @cluster.dump_all
    end

    def on_shutdown
      dump_all
      STDOUT.puts "\nKarma v.#{Karma::VERSION} is off."
    end
  end
end