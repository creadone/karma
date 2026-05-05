module Karma
  module Wal
    def self.append(directive : Commands::Directive) : Bool
      return true unless enabled?

      dump_dir = File.expand_path(Karma.config.dump_dir)
      Dir.mkdir_p(dump_dir) unless Dir.exists?(dump_dir)

      with_next_lsn(dump_dir) do |lsn|
        File.open(path(dump_dir), "a") do |io|
          io.puts serialize(directive, lsn)
          io.flush
          io.fsync if fsync?
        end
      end

      true
    end

    def self.truncate : Bool
      return true unless enabled?

      dump_dir = File.expand_path(Karma.config.dump_dir)
      Dir.mkdir_p(dump_dir) unless Dir.exists?(dump_dir)

      File.open(path, "w") do |io|
        io.flush
        io.fsync if fsync?
      end
      Karma::Log.info("wal.truncate", "path=#{path}")

      true
    end
  end
end
