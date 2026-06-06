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
    class FastIncrementJob
      getter cluster : Cluster
      getter series_name : String
      getter key : UInt64
      getter bucket : UInt64
      getter value : UInt64
      getter result : Channel(Exception?)

      def initialize(@cluster : Cluster, @series_name : String, @key : UInt64, @bucket : UInt64, @value : UInt64, @result : Channel(Exception?))
      end
    end

    @@fast_increment_channel : Channel(FastIncrementJob)?
    @@fast_increment_start_mutex = Mutex.new

    def self.call(message, cluster, persist = true, authorize = true, synchronize = true, enforce_request_size = true, enforce_role = true)
      started_at = Time.monotonic
      protocol_version = Karma::Protocol::VERSION
      if enforce_request_size && request_too_large?(message)
        Karma::Operations.record_command(false, elapsed_ms(started_at))
        return Karma::Protocol.error("request_too_large", "Request exceeds #{Karma.config.max_request_bytes} bytes", protocol_version)
      end

      begin
        payload = JSON.parse(message)
        object = payload.as_h
        require_v2_request!(object)
        if fast_answer = fast_path(object, cluster, persist, authorize, synchronize, enforce_role)
          Karma::Operations.record_command(true, elapsed_ms(started_at))
          return fast_answer
        end

        directive = parse_object(message, object)

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

    private def self.fast_path(object : Hash(String, JSON::Any), cluster, persist : Bool, authorize : Bool, synchronize : Bool, enforce_role : Bool) : String?
      return nil if authorize && (Karma.config.auth_token || Karma.config.read_auth_token)
      return nil if object.has_key?("token") || object.has_key?("idempotency_key") || object.has_key?("fingerprint") || object.has_key?("idempotency_created_at_unix")

      op = object["op"].as_s
      case op
      when "counter.sum", "series.sum"
        return nil if object.has_key?("range")

        series_name = tree_or_series(object)
        key = key_from(object)
        result = if synchronize
                   Karma::State.synchronize_series(series_name) do
                     fast_tree_required(series_name, cluster).sum(key)
                   end
                 else
                   fast_tree_required(series_name, cluster).sum(key)
                 end
        Karma::Protocol.success_uint64(result)
      when "counter.increment", "series.increment"
        return nil if object.has_key?("range")
        return nil if enforce_role && Karma.config.role == "slave"

        series_name = tree_or_series(object)
        key = key_from(object)
        bucket = date_or_bucket(object) || Karma::TimeSeries::Bucket.today.value
        value = value_from(object) || 1_u64
        raise Karma::Error.new("validation_error", "Field value must be greater than 0") if value == 0_u64

        if synchronize && persist && Karma::Wal.enabled?
          apply_fast_increment_batched(series_name, key, bucket, value, cluster)
        else
          apply_fast_increment(series_name, key, bucket, value, cluster, persist, synchronize)
        end
        Karma::Protocol.success_uint64(value)
      else
        nil
      end
    end

    private def self.apply_fast_increment_batched(series_name : String, key : UInt64, bucket : UInt64, value : UInt64, cluster : Cluster) : UInt64
      result = Channel(Exception?).new(1)
      fast_increment_channel.send(FastIncrementJob.new(cluster, series_name, key, bucket, value, result))
      if error = result.receive
        raise error
      end

      value
    end

    private def self.apply_fast_increment(series_name : String, key : UInt64, bucket : UInt64, value : UInt64, cluster, persist : Bool, synchronize : Bool) : UInt64
      if synchronize
        Karma::State.synchronize_series(series_name) do
          apply_fast_increment(series_name, key, bucket, value, cluster, persist, synchronize: false)
        end
      else
        tree = fast_tree(cluster, series_name)
        counter = tree.try(&.get(key))
        if counter
          current = counter.table[bucket]? || 0_u64
          if UInt64::MAX - current < value || UInt64::MAX - counter.total < value
            raise Karma::Error.new("validation_error", "Counter overflow key=#{key} bucket=#{bucket}")
          end
        end

        if persist && Karma::Wal.enabled?
          directive = Directive.new("increment", tree_name: series_name, key: key, date: bucket, value: value, protocol_version: Karma::Protocol::VERSION)
          Karma::Wal.append(directive)
        end

        if counter
          counter.increment(bucket, value)
        elsif tree
          tree.increment(key, bucket, value)
        else
          tree = fast_tree_or_create(cluster, series_name)
          tree.increment(key, bucket, value)
        end
      end
    end

    private def self.fast_increment_channel : Channel(FastIncrementJob)
      channel = @@fast_increment_channel
      return channel if channel

      @@fast_increment_start_mutex.synchronize do
        channel = @@fast_increment_channel
        return channel if channel

        channel = Channel(FastIncrementJob).new
        @@fast_increment_channel = channel
        spawn fast_increment_worker_loop(channel)
        channel
      end
    end

    private def self.fast_increment_worker_loop(channel : Channel(FastIncrementJob)) : Nil
      loop do
        jobs = [channel.receive]
        drain_fast_increment_jobs(channel, jobs)
        process_fast_increment_jobs(jobs)
      end
    rescue ex
      Karma::Log.error("counter.increment_batcher_stopped", ex.message || ex.class.name)
    end

    private def self.drain_fast_increment_jobs(channel : Channel(FastIncrementJob), jobs : Array(FastIncrementJob)) : Nil
      max = Karma.config.wal_batch_size
      max = 1 if max < 1

      Fiber.yield
      drain_available_fast_increment_jobs(channel, jobs, max)
      return if jobs.size >= max

      wait_us = Karma.config.wal_batch_wait_microseconds
      return if wait_us <= 0

      deadline = Time.monotonic + wait_us.microseconds
      loop do
        break if jobs.size >= max
        remaining = deadline - Time.monotonic
        break if remaining <= Time::Span.zero

        select
        when job = channel.receive
          jobs << job
        when timeout(remaining)
          break
        end
      end
    end

    private def self.drain_available_fast_increment_jobs(channel : Channel(FastIncrementJob), jobs : Array(FastIncrementJob), max : Int32) : Nil
      loop do
        break if jobs.size >= max

        select
        when job = channel.receive
          jobs << job
        when timeout(Time::Span.zero)
          break
        end
      end
    end

    private def self.process_fast_increment_jobs(jobs : Array(FastIncrementJob)) : Nil
      index = 0
      while index < jobs.size
        cluster = jobs[index].cluster
        series_name = jobs[index].series_name
        group = [] of FastIncrementJob
        while index < jobs.size && jobs[index].cluster == cluster && jobs[index].series_name == series_name
          group << jobs[index]
          index += 1
        end
        process_fast_increment_group(cluster, series_name, group)
      end
    end

    private def self.process_fast_increment_group(cluster : Cluster, series_name : String, jobs : Array(FastIncrementJob)) : Nil
      error : Exception? = nil
      begin
        Karma::State.synchronize_series(series_name) do
          tree = fast_tree(cluster, series_name)
          preflight_fast_increment_group(tree, jobs)
          directives = jobs.map do |job|
            Directive.new("increment", tree_name: series_name, key: job.key, date: job.bucket, value: job.value, protocol_version: Karma::Protocol::VERSION)
          end
          Karma::Wal.append(directives)

          tree = fast_tree_or_create(cluster, series_name)
          jobs.each do |job|
            tree.increment(job.key, job.bucket, job.value)
          end
        end
      rescue ex
        error = ex
      end

      jobs.each { |job| job.result.send(error) }
    end

    private def self.preflight_fast_increment_group(tree : Karma::BucketedCounter::Store?, jobs : Array(FastIncrementJob)) : Nil
      bucket_totals = {} of Tuple(UInt64, UInt64) => UInt64
      counter_totals = {} of UInt64 => UInt64

      jobs.each do |job|
        counter = tree.try(&.get(job.key))
        bucket_key = {job.key, job.bucket}
        current_bucket = bucket_totals.fetch(bucket_key) do
          counter.try(&.table[job.bucket]?) || 0_u64
        end
        current_total = counter_totals.fetch(job.key) do
          counter.try(&.total) || 0_u64
        end

        if UInt64::MAX - current_bucket < job.value || UInt64::MAX - current_total < job.value
          raise Karma::Error.new("validation_error", "Counter overflow key=#{job.key} bucket=#{job.bucket}")
        end

        bucket_totals[bucket_key] = current_bucket + job.value
        counter_totals[job.key] = current_total + job.value
      end
    end

    private def self.fast_tree(cluster, series_name : String) : Karma::BucketedCounter::Store?
      Karma::State.synchronize_registry do
        cluster.trees[series_name]?
      end
    end

    private def self.fast_tree_required(series_name : String, cluster) : Karma::BucketedCounter::Store
      fast_tree(cluster, series_name) || raise Karma::Error.new("not_found", "Tree \"#{series_name}\" not found")
    end

    private def self.fast_tree_or_create(cluster, series_name : String) : Karma::BucketedCounter::Store
      Karma::State.synchronize_registry do
        cluster.trees[series_name] ||= Karma::BucketedCounter::Store.new
      end
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
        tree = Karma::BucketedCounter::Store.new
        cluster.trees[series_name] = tree
        tree.increment(key, bucket, value)
      end
    end

    private def self.preflight(directive : Directive, cluster) : Nil
      case directive.command
      when "increment"
        preflight_increment(directive, cluster)
      when "batch_add"
        tree = cluster.trees[directive.series_name]? || Karma::BucketedCounter::Store.new
        Commands::BatchAdd.preflight!(tree, directive.items.not_nil!)
      when "batch_set"
        tree = cluster.trees[directive.series_name]? || Karma::BucketedCounter::Store.new
        Commands::BatchSet.preflight!(tree, directive.items.not_nil!)
      when "batch_reset", "batch_delete_range"
        cluster.get(directive.series_name)
      end
    end

    private def self.preflight_increment(directive : Directive, cluster) : Nil
      tree = cluster.trees[directive.series_name]? || Karma::BucketedCounter::Store.new
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
