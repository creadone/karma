require "./karma"

begin
  Karma::Cli.parse!
  launcher = Karma::Launcher.new
  Karma::Signals.install!(launcher)
  launcher.run!
rescue ex : Karma::Error
  STDERR.puts "ERROR: #{ex.message}"
  exit(1)
end
