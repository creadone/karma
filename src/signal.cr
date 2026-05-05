module Karma
  module Signals
    def self.install!(launcher : Launcher) : Nil
      Signal::INT.trap do
        spawn launcher.on_shutdown
        sleep 100.milliseconds
        exit(-1)
      end

      Signal::USR1.trap do
        spawn launcher.dump_all
        sleep 100.milliseconds
      end
    end
  end
end
