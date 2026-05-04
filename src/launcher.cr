module Karma
  class Launcher
    def initialize
      @cluster = uninitialized Karma::Cluster
      @server = uninitialized Karma::Server
    end

    def run!
      if Karma.config.restore
        @cluster = Cluster.restore_with_wal(Karma.config.dump_dir)
      else
        @cluster = Cluster.new
      end
      @server = Karma::Server.new(@cluster)
      Karma::Log.info("server.start", "version=#{Karma::VERSION} port=#{Karma.config.port}")
      @server.start!
    end

    def dump_all
      Karma::State.synchronize do
        @cluster.dump_all
      end
    end

    def on_shutdown
      dump_all
      Karma::Log.info("server.stop", "version=#{Karma::VERSION}")
    end
  end
end
