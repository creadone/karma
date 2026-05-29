require "json"
require "./commands/directive"
require "./commands/counter/*"
require "./commands/idempotency/*"
require "./commands/ingest/*"
require "./commands/snapshot/*"
require "./commands/system/*"
require "./commands/tree/*"
require "./commands/registry"
require "./commands/request_fields"
require "./commands/v2_parser"
require "./commands/parser"
require "./commands/validation_rules"
require "./commands/validator"

module Karma
  module Commands
    def self.call(message, cluster, persist = true, authorize = true, synchronize = true, track_legacy = true, enforce_request_size = true, enforce_role = true)
      started_at = Time.monotonic
      protocol_version = request_protocol_version(message)
      if enforce_request_size && request_too_large?(message)
        Karma::Operations.record_command(false, elapsed_ms(started_at))
        return Karma::Protocol.error("request_too_large", "Request exceeds #{Karma.config.max_request_bytes} bytes", protocol_version)
      end

      begin
        payload = JSON.parse(message)
        object = payload.as_h
        protocol_version = request_protocol_version(object)
        directive = parse_object(message, object)
        protocol_version = directive.protocol_version
        if track_legacy && protocol_version == Karma::Protocol::VERSION
          Karma::Operations.record_legacy_request
          Karma::Log.info("protocol.v1_request", "command=#{directive.command}")
        end

        if known?(directive)
          authenticate(directive) if authorize
          validate(directive)
          enforce_role!(directive) if enforce_role
          applied = apply(directive, cluster, persist, synchronize)
          idempotent = nil
          response = if applied.is_a?(Karma::Idempotency::Result)
                       idempotent = applied.idempotent
                       applied.value
                     else
                       applied
                     end
          answer = Karma::Protocol.success(response, protocol_version, idempotent: idempotent)
          if response_too_large?(answer)
            Karma::Operations.record_command(false, elapsed_ms(started_at))
            return Karma::Protocol.error("response_too_large", "Response exceeds #{Karma.config.max_response_bytes} bytes", protocol_version)
          end

          Karma::Operations.record_command(true, elapsed_ms(started_at))
          return answer
        else
          raise Karma::Error.new("unknown_command", "Unknown command #{directive.command}")
        end
      rescue e : JSON::ParseException
        Karma::Operations.record_command(false, elapsed_ms(started_at))
        return Karma::Protocol.error("invalid_json", e.message || "Invalid JSON", protocol_version)
      rescue e : KeyError | TypeCastError
        Karma::Operations.record_command(false, elapsed_ms(started_at))
        return Karma::Protocol.error("validation_error", e.message || "Invalid request", protocol_version)
      rescue e : Karma::Error
        Karma::Operations.record_command(false, elapsed_ms(started_at))
        return Karma::Protocol.error(e.code, e.message || e.code, protocol_version)
      rescue e
        Karma::Operations.record_command(false, elapsed_ms(started_at))
        return Karma::Protocol.error("internal_error", e.message || e.class.name, protocol_version)
      end
    end

    private def self.request_protocol_version(message : String) : UInt32
      payload = JSON.parse(message)
      request_protocol_version(payload.as_h)
    rescue
      Karma::Protocol::VERSION
    end

    private def self.request_protocol_version(object : Hash(String, JSON::Any)) : UInt32
      return 2_u32 if object.has_key?("op") || object["v"]?.try(&.as_i?) == 2

      Karma::Protocol::VERSION
    end

    private def self.elapsed_ms(started_at : Time::Span) : Float64
      (Time.monotonic - started_at).total_milliseconds
    end

    private def self.request_too_large?(message : String) : Bool
      max_request_bytes = Karma.config.max_request_bytes
      max_request_bytes > 0 && message.bytesize > max_request_bytes
    end

    private def self.response_too_large?(response : String) : Bool
      max_response_bytes = Karma.config.max_response_bytes
      max_response_bytes > 0 && response.bytesize > max_response_bytes
    end

    private def self.apply(directive : Directive, cluster, persist : Bool, synchronize : Bool)
      if synchronize
        Karma::State.synchronize { apply(directive, cluster, persist, synchronize: false) }
      elsif Karma::Idempotency.eligible?(directive)
        Karma::Idempotency.execute(directive, use_persisted_timestamp: !persist) do
          apply_idempotent_mutation(directive, cluster, persist)
        end
      else
        Karma::Wal.append(directive) if persist && Karma::Wal.persist?(directive)
        COMMANDS[directive.command].call(directive, cluster)
      end
    end

    private def self.apply_idempotent_mutation(directive : Directive, cluster, persist : Bool)
      return apply_idempotent_increment(directive, cluster, persist) if directive.command == "increment"

      preflight(directive, cluster)
      Karma::Wal.append(directive) if persist && Karma::Wal.persist?(directive)
      COMMANDS[directive.command].call(directive, cluster)
    end

    private def self.apply_idempotent_increment(directive : Directive, cluster, persist : Bool) : UInt64
      series_name = directive.series_name
      key = directive.key_value
      bucket = directive.write_bucket.value
      value = directive.write_value
      tree = cluster.trees[series_name]?
      counter = tree.try(&.get(key))

      if counter
        current = counter.table[bucket]? || 0_u64
        if UInt64::MAX - current < value || UInt64::MAX - counter.total < value
          raise Karma::Error.new("validation_error", "Counter overflow key=#{key} bucket=#{bucket}")
        end
      end

      Karma::Wal.append(directive) if persist && Karma::Wal.persist?(directive)

      if counter
        counter.increment(bucket, value)
      elsif tree
        tree.increment(key, bucket, value)
      else
        tree = CounterTree::Tree.new
        cluster.trees[series_name] = tree
        tree.increment(key, bucket, value)
      end
    end

    private def self.preflight(directive : Directive, cluster) : Nil
      case directive.command
      when "increment"
        preflight_increment(directive, cluster)
      when "batch_add"
        tree = cluster.trees[directive.series_name]? || CounterTree::Tree.new
        Commands::BatchAdd.preflight!(tree, directive.items.not_nil!)
      when "batch_set"
        tree = cluster.trees[directive.series_name]? || CounterTree::Tree.new
        Commands::BatchSet.preflight!(tree, directive.items.not_nil!)
      when "batch_reset", "batch_delete_range"
        cluster.get(directive.series_name)
      end
    end

    private def self.preflight_increment(directive : Directive, cluster) : Nil
      tree = cluster.trees[directive.series_name]? || CounterTree::Tree.new
      counter = tree.get(directive.key_value)
      current = counter.try(&.table[directive.write_bucket.value]?) || 0_u64
      if UInt64::MAX - current < directive.write_value
        raise Karma::Error.new("validation_error", "Counter overflow key=#{directive.key_value} bucket=#{directive.write_bucket.value}")
      end
    end

    private def self.enforce_role!(directive : Directive) : Nil
      return unless Karma.config.role == "slave"
      return if read_only?(directive)

      raise Karma::Error.new("forbidden", "Slave role cannot execute command #{directive.command}")
    end

    private def self.authenticate(directive : Directive) : Nil
      write_token = Karma.config.auth_token
      read_token = Karma.config.read_auth_token
      return if write_token.nil? && read_token.nil?
      return if write_token && directive.token == write_token
      return if read_token && directive.token == read_token && read_only?(directive)

      if read_token && directive.token == read_token
        raise Karma::Error.new("forbidden", "Read-only token cannot execute command #{directive.command}")
      end

      raise Karma::Error.new("unauthorized", "Unauthorized")
    end
  end
end
