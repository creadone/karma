module Karma
  module Wal
    FILE_NAME = "karma.wal"

    def self.enabled? : Bool
      Karma.config.wal
    end

    def self.fsync? : Bool
      Karma.config.wal_fsync
    end

    def self.path(dump_dir = Karma.config.dump_dir) : String
      File.join(File.expand_path(dump_dir), FILE_NAME)
    end

    def self.persist?(directive : Commands::Directive) : Bool
      Commands.mutating?(directive)
    end
  end
end

require "./wal/serializer"
require "./wal/store"
require "./wal/replay"
