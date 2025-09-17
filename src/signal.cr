module Karma

  Signal::INT.trap do
    spawn Karma::LAUNCHER.on_shutdown
    sleep 100.milliseconds
    exit(-1)
  end

  Signal::USR1.trap do
    spawn Karma::LAUNCHER.dump_all
    sleep 100.milliseconds
  end

end