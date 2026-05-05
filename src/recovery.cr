require "json"
require "random/secure"

module Karma
  module Recovery
    FILE_NAME = "recovery.json"
    MUTEX     = Mutex.new

    struct Checkpoint
      include JSON::Serializable

      getter source : String
      getter offset : String?
      getter event_id : String?
      getter updated_at_unix : Int64

      def initialize(@source : String, @offset : String?, @event_id : String?, @updated_at_unix : Int64)
      end

      def to_response
        {
          source:          source,
          offset:          offset,
          event_id:        event_id,
          updated_at_unix: updated_at_unix,
        }
      end
    end

    struct Document
      include JSON::Serializable

      getter checkpoints : Array(Checkpoint)

      def initialize(@checkpoints : Array(Checkpoint))
      end
    end

    @@checkpoints = Hash(String, Checkpoint).new

    def self.path(dump_dir = Karma.config.dump_dir) : String
      File.join(File.expand_path(dump_dir), FILE_NAME)
    end

    def self.checkpoint(source : String, offset : String?, event_id : String?, dump_dir = Karma.config.dump_dir) : Checkpoint
      checkpoint = Checkpoint.new(source, offset, event_id, Time.utc.to_unix)
      MUTEX.synchronize do
        @@checkpoints[source] = checkpoint
      end
      persist!(dump_dir)
      checkpoint
    end

    def self.status(source : String? = nil)
      checkpoints = if source
                      checkpoint = MUTEX.synchronize { @@checkpoints[source]? }
                      checkpoint ? [checkpoint] : [] of Checkpoint
                    else
                      MUTEX.synchronize { @@checkpoints.values.sort_by(&.source) }
                    end

      {
        checkpoint_count: checkpoints.size,
        checkpoints:      checkpoints.map(&.to_response),
      }
    end

    def self.checkpoint_count : Int32
      MUTEX.synchronize { @@checkpoints.size }
    end

    def self.last_checkpoint_unix : Int64
      MUTEX.synchronize do
        @@checkpoints.values.max_of?(&.updated_at_unix) || 0_i64
      end
    end

    def self.load!(dump_dir = Karma.config.dump_dir) : Nil
      file_path = path(dump_dir)
      reset!
      return unless File.exists?(file_path)

      document = Document.from_json(File.read(file_path))
      MUTEX.synchronize do
        @@checkpoints.clear
        document.checkpoints.each do |checkpoint|
          @@checkpoints[checkpoint.source] = checkpoint
        end
      end
      Karma::Log.info("recovery.load", "path=#{file_path} checkpoints=#{document.checkpoints.size}")
    end

    def self.reset! : Nil
      MUTEX.synchronize { @@checkpoints.clear }
    end

    private def self.persist!(dump_dir : String) : Nil
      dump_dir = File.expand_path(dump_dir)
      Dir.mkdir_p(dump_dir) unless Dir.exists?(dump_dir)

      checkpoints = MUTEX.synchronize { @@checkpoints.values.sort_by(&.source) }
      file_path = path(dump_dir)
      temp_path = File.join(
        dump_dir,
        ".#{FILE_NAME}.#{Process.pid}.#{Random::Secure.hex(8)}.tmp"
      )

      File.open(temp_path, "w") do |io|
        Document.new(checkpoints).to_json(io)
        io.puts
        io.flush
        io.fsync
      end

      File.rename(temp_path, file_path)
      Karma::Log.info("recovery.checkpoint", "path=#{file_path} checkpoints=#{checkpoints.size}")
    ensure
      File.delete(temp_path) if temp_path && File.exists?(temp_path)
    end
  end
end
