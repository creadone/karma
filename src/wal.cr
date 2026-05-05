require "json"

module Karma
  module Wal
    FILE_NAME         = "karma.wal"
    MUTATING_COMMANDS = %w[create drop increment decrement delete reset batch_add delete_before compact ingest_begin ingest_chunk ingest_commit ingest_abort]

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
          json.field "v", 2
          write_operation(json, directive)
        end
      end
    end

    private def self.write_operation(json : JSON::Builder, directive : Commands::Directive) : Nil
      case directive.command
      when "create"
        json.field "op", "tree.create"
        json.field "tree", directive.tree_name
      when "drop"
        json.field "op", "tree.drop"
        json.field "tree", directive.tree_name
      when "increment"
        json.field "op", "counter.increment"
        json.field "tree", directive.tree_name
        json.field "key", directive.key
        json.field "date", directive.date || Karma::TimeSeries::Bucket.today.value
        json.field "value", directive.value || 1_u64
      when "decrement"
        json.field "op", "counter.decrement"
        json.field "tree", directive.tree_name
        json.field "key", directive.key
        json.field "date", directive.date || Karma::TimeSeries::Bucket.today.value
        json.field "value", directive.value || 1_u64
      when "batch_add"
        json.field "op", "series.batch_add"
        json.field "series", directive.tree_name
        json.field "granularity", "day"
        json.field "items", directive.items
      when "delete_before"
        json.field "op", "series.delete_before"
        json.field "series", directive.tree_name
        json.field "before", directive.date
      when "compact"
        if directive.tree_name
          json.field "op", "series.compact"
          json.field "series", directive.tree_name
        else
          json.field "op", "system.compact"
        end
      when "ingest_begin"
        json.field "op", "ingest.begin"
        json.field "stream_id", directive.stream_id
        json.field "mode", directive.mode
        json.field "granularity", directive.granularity unless directive.granularity.nil?
      when "ingest_chunk"
        json.field "op", "ingest.chunk"
        json.field "stream_id", directive.stream_id
        json.field "series", directive.tree_name
        json.field "chunk_seq", directive.chunk_seq
        json.field "items", directive.items
      when "ingest_commit"
        json.field "op", "ingest.commit"
        json.field "stream_id", directive.stream_id
      when "ingest_abort"
        json.field "op", "ingest.abort"
        json.field "stream_id", directive.stream_id
      when "delete"
        if directive.key
          json.field "op", "counter.delete_range"
          json.field "tree", directive.tree_name
          json.field "key", directive.key
          write_range(json, directive)
        else
          json.field "op", "tree.delete_range"
          json.field "tree", directive.tree_name
          write_range(json, directive)
        end
      when "reset"
        if directive.key
          json.field "op", "counter.reset"
          json.field "tree", directive.tree_name
          json.field "key", directive.key
        else
          json.field "op", "tree.reset"
          json.field "tree", directive.tree_name
        end
      else
        raise Karma::Error.new("validation_error", "Cannot serialize #{directive.command} to WAL")
      end
    end

    private def self.write_range(json : JSON::Builder, directive : Commands::Directive) : Nil
      json.field "range" do
        json.object do
          json.field "from", directive.time_from
          json.field "to", directive.time_to
        end
      end
    end
  end
end
