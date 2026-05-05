module Karma
  module Signals
    def self.install!(launcher : Launcher) : Nil
      Signal::INT.trap do
        spawn do
          launcher.shutdown!
          exit(0)
        end
      end

      Signal::USR1.trap do
        spawn launcher.dump_all
      end
    end
  end
end
