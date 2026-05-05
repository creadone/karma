module Karma
  module Wal
    FILE_NAME     = "karma.wal"
    LSN_FILE_NAME = "karma.wal.lsn"

    def self.enabled? : Bool
      Karma.config.wal
    end

    def self.fsync? : Bool
      Karma.config.wal_fsync
    end

    def self.path(dump_dir = Karma.config.dump_dir) : String
      File.join(File.expand_path(dump_dir), FILE_NAME)
    end

    def self.lsn_path(dump_dir = Karma.config.dump_dir) : String
      File.join(File.expand_path(dump_dir), LSN_FILE_NAME)
    end

    def self.persist?(directive : Commands::Directive) : Bool
      Commands.mutating?(directive) && directive.command != "recovery_checkpoint"
    end
  end
end

require "./wal/serializer"
require "./wal/lsn"
require "./wal/entry"
require "./wal/store"
require "./wal/replay"
