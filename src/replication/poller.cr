require "json"
require "socket"

module Karma
  module Replication
    class Poller
      getter host : String
      getter port : Int32
      getter limit : Int32

      @fiber : Fiber?
      @stopped : Channel(Nil)?

      def self.build?(cluster : Cluster) : Poller?
        return nil unless Karma.config.role == "slave"
        return nil unless host = Karma.config.replication_source_host

        new(
          cluster,
          host,
          Karma.config.replication_source_port,
          Karma.config.replication_batch_size,
          Karma.config.replication_poll_interval_ms.milliseconds,
          Karma.config.replication_token
        )
      end

      def initialize(
        @cluster : Cluster,
        @host : String,
        @port : Int32,
        @limit : Int32 = 1_000,
        @interval : Time::Span = 1.second,
        @token : String? = nil,
      )
        @stopping = false
        @fiber = nil
        @stopped = nil
      end

      def start! : Nil
        return if @fiber

        Karma::Log.info("replication.poller_start", "source=#{@host}:#{@port} limit=#{@limit}")
        @stopped = Channel(Nil).new
        @fiber = spawn run
      end

      def stop! : Nil
        @stopping = true
        @stopped.try(&.receive?)
        @fiber = nil
        @stopped = nil
      end

      def poll_once : UInt64
        after_lsn = Karma::Replication.replayed_lsn
        response = request_entries(after_lsn)
        Karma::Replication.record_source_lsn(response.source_lsn)
        Karma::Replication.apply(response.entries, @cluster)
      end

      private def run : Nil
        until @stopping
          begin
            poll_once
          rescue ex
            Karma::Log.error("replication.poll_failed", ex.message || ex.class.name)
          end

          sleep @interval unless @stopping
        end
        Karma::Log.info("replication.poller_stop", "source=#{@host}:#{@port}")
      ensure
        @stopped.try(&.send(nil))
      end

      protected def request_entries(after_lsn : UInt64) : Response
        socket = TCPSocket.new(@host, @port)
        socket.read_timeout = Karma.config.read_timeout_seconds.seconds if Karma.config.read_timeout_seconds > 0
        socket.write_timeout = Karma.config.write_timeout_seconds.seconds if Karma.config.write_timeout_seconds > 0
        socket << request_json(after_lsn) << "\n"
        line = socket.gets
        raise Karma::Error.new("replication_error", "Master closed connection without response") unless line

        parse_response(line)
      ensure
        socket.try(&.close)
      end

      private def request_json(after_lsn : UInt64) : String
        JSON.build do |json|
          json.object do
            json.field "v", 2
            json.field "op", "replication.entries"
            json.field "after_lsn", after_lsn
            json.field "limit", @limit
            json.field "token", @token if @token
          end
        end
      end

      private def parse_response(line : String) : Response
        parsed = JSON.parse(line)
        unless parsed["success"].as_bool
          raise Karma::Error.new("replication_error", "Master rejected replication request: #{parsed["response"]}")
        end

        response = parsed["response"]
        source_lsn = response["source_lsn"]?.try(&.as_i64.to_u64) || response["next_lsn"].as_i64.to_u64
        entries = response["entries"].as_a.map { |entry| Karma::Wal::Entry.from_response(entry) }
        Response.new(source_lsn, entries)
      end

      struct Response
        getter source_lsn : UInt64
        getter entries : Array(Karma::Wal::Entry)

        def initialize(@source_lsn : UInt64, @entries : Array(Karma::Wal::Entry))
        end
      end
    end
  end
end
