module Karma
  class Config
    INSTANCE = Config.new

    property host        : String  = "0.0.0.0"
    property port        : Int32   = 8080
    property dump_dir    : String  = "."
    property restore     : Bool    = true
    property tcp_nodelay : Bool    = true
  end

  def self.configure
    yield Config::INSTANCE
  end

  def self.config
    Config::INSTANCE
  end
end