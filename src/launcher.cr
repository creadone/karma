module Karma
  class Launcher
    def initialize(@runtime : Runtime? = nil)
    end

    def run!
      runtime = @runtime ||= Runtime.build
      Karma::Log.info("server.start", "version=#{Karma::VERSION} port=#{Karma.config.port}")
      runtime.server.start!
    end

    def dump_all
      return unless runtime = @runtime

      Karma::State.synchronize do
        runtime.cluster.dump_all
      end
    end

    def on_shutdown
      shutdown!
    end

    def shutdown! : Nil
      @runtime.try(&.server.stop!)
      dump_all
      Karma::Log.info("server.stop", "version=#{Karma::VERSION}")
    end
  end
end
