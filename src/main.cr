require "./karma"

Karma::Cli.parse!
launcher = Karma::Launcher.new
Karma::Signals.install!(launcher)
launcher.run!
