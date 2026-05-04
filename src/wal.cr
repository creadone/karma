require "json"

module Karma
  module Wal
    FILE_NAME         = "karma.wal"
    MUTATING_COMMANDS = %w[create drop increment decrement delete reset]

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
      MUTATING_COMMANDS.includes?(directive.command)
    end

    def self.append(directive : Commands::Directive) : Bool
      return true unless enabled?

      dump_dir = File.expand_path(Karma.config.dump_dir)
      Dir.mkdir_p(dump_dir) unless Dir.exists?(dump_dir)

      File.open(path, "a") do |io|
        io.puts serialize(directive)
        io.flush
        io.fsync if fsync?
      end

      true
    end

    def self.replay(cluster : Cluster, dump_dir = Karma.config.dump_dir) : Nil
      return unless enabled?
      wal_path = path(dump_dir)
      return unless File.exists?(wal_path)

      File.each_line(wal_path) do |line|
        next if line.blank?

        response = Commands.call(line, cluster, persist: false, authorize: false, synchronize: false)
        parsed_response = JSON.parse(response)
        unless parsed_response["success"].as_bool
          raise "Cannot replay WAL entry: #{parsed_response["response"]}"
        end
      end
      Karma::Log.info("wal.replay", "path=#{wal_path}")
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

    private def self.serialize(directive : Commands::Directive) : String
      JSON.build do |json|
        json.object do
          json.field "command", directive.command
          json.field "tree_name", directive.tree_name unless directive.tree_name.nil?
          json.field "key", directive.key unless directive.key.nil?
          json.field "time_from", directive.time_from unless directive.time_from.nil?
          json.field "time_to", directive.time_to unless directive.time_to.nil?
        end
      end
    end
  end
end
