require "json"
require "./commands/*"

module Karma
  module Commands
    struct Directive
      include JSON::Serializable

      property command : String
      property tree_name : String?
      property key : UInt64?
      property time_from : UInt64?
      property time_to : UInt64?
      property token : String?
    end

    COMMANDS = {
      "trees"     => Commands::Trees,
      "create"    => Commands::Create,
      "drop"      => Commands::Drop,
      "dump"      => Commands::Dump,
      "dump_all"  => Commands::DumpAll,
      "dumps"     => Commands::Dumps,
      "load"      => Commands::Load,
      "increment" => Commands::Increment,
      "decrement" => Commands::Decrement,
      "sum"       => Commands::Sum,
      "find"      => Commands::Find,
      "reset"     => Commands::Reset,
      "delete"    => Commands::Delete,
      "health"    => Commands::Health,
      "stats"     => Commands::Stats,
      "metrics"   => Commands::Metrics,
      "verify"    => Commands::Verify,
      "ping"      => Commands::Ping,
    }

    def self.call(message, cluster, persist = true, authorize = true, synchronize = true)
      started_at = Time.monotonic
      begin
        directive = Directive.from_json(message)
        if COMMANDS.has_key?(directive.command)
          authenticate(directive) if authorize
          validate(directive)
          response = apply(directive, cluster, persist, synchronize)
          Karma::Operations.record_command(true, elapsed_ms(started_at))
          return Karma::Protocol.success(response)
        else
          raise Karma::Error.new("unknown_command", "Unknown command #{directive.command}")
        end
      rescue e : JSON::ParseException
        Karma::Operations.record_command(false, elapsed_ms(started_at))
        return Karma::Protocol.error("invalid_json", e.message || "Invalid JSON")
      rescue e : Karma::Error
        Karma::Operations.record_command(false, elapsed_ms(started_at))
        return Karma::Protocol.error(e.code, e.message || e.code)
      rescue e
        Karma::Operations.record_command(false, elapsed_ms(started_at))
        return Karma::Protocol.error("internal_error", e.message || e.class.name)
      end
    end

    private def self.elapsed_ms(started_at : Time::Span) : Float64
      (Time.monotonic - started_at).total_milliseconds
    end

    private def self.apply(directive : Directive, cluster, persist : Bool, synchronize : Bool)
      if synchronize
        Karma::State.synchronize { apply(directive, cluster, persist, synchronize: false) }
      else
        Karma::Wal.append(directive) if persist && Karma::Wal.persist?(directive)
        COMMANDS[directive.command].call(directive, cluster)
      end
    end

    private def self.authenticate(directive : Directive) : Nil
      token = Karma.config.auth_token
      return if token.nil?
      return if directive.token == token

      raise Karma::Error.new("unauthorized", "Unauthorized")
    end

    private def self.validate(directive : Directive) : Nil
      case directive.command
      when "ping", "trees", "dumps", "dump_all", "health", "stats", "metrics", "verify"
      when "create", "drop", "dump", "load", "reset"
        require_tree_name(directive)
      when "increment", "decrement"
        require_tree_name(directive)
        require_key(directive)
      when "sum"
        require_tree_name(directive)
        require_key(directive)
        require_complete_range(directive) if directive.time_from || directive.time_to
      when "find", "delete"
        require_tree_name(directive)
        require_complete_range(directive)
      else
        raise Karma::Error.new("unknown_command", "Unknown command #{directive.command}")
      end
    end

    private def self.require_tree_name(directive : Directive) : Nil
      return unless directive.tree_name.nil? || directive.tree_name.to_s.empty?

      raise Karma::Error.new("validation_error", "Field tree_name is required")
    end

    private def self.require_key(directive : Directive) : Nil
      return unless directive.key.nil?

      raise Karma::Error.new("validation_error", "Field key is required")
    end

    private def self.require_complete_range(directive : Directive) : Nil
      if directive.time_from.nil? || directive.time_to.nil?
        raise Karma::Error.new("validation_error", "Fields time_from and time_to are required together")
      end

      if directive.time_from.as(UInt64) > directive.time_to.as(UInt64)
        raise Karma::Error.new("validation_error", "Field time_from must be less than or equal to time_to")
      end
    end
  end
end
