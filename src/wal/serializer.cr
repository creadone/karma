require "json"

module Karma
  module Wal
    private def self.serialize(directive : Commands::Directive, lsn : UInt64? = nil) : String
      JSON.build do |json|
        if lsn
          json.object do
            json.field "v", 2
            json.field "lsn", lsn
            json.field "entry" do
              write_command(json, directive)
            end
          end
        else
          write_command(json, directive)
        end
      end
    end

    private def self.write_command(json : JSON::Builder, directive : Commands::Directive) : Nil
      json.object do
        json.field "v", 2
        write_operation(json, directive)
        json.field "idempotency_key", directive.idempotency_key if directive.idempotency_key
        json.field "fingerprint", directive.fingerprint if directive.fingerprint
        json.field "idempotency_created_at_unix", directive.idempotency_created_at_unix if directive.idempotency_created_at_unix
      end
    end

    private def self.write_operation(json : JSON::Builder, directive : Commands::Directive) : Nil
      case directive.command
      when "create"
        json.field "op", "tree.create"
        json.field "series", directive.tree_name
      when "drop"
        json.field "op", "tree.drop"
        json.field "series", directive.tree_name
      when "increment"
        json.field "op", "counter.increment"
        json.field "series", directive.tree_name
        json.field "key", directive.key
        json.field "bucket", directive.date || Karma::TimeSeries::Bucket.today.value
        json.field "value", directive.value || 1_u64
      when "decrement"
        json.field "op", "counter.decrement"
        json.field "series", directive.tree_name
        json.field "key", directive.key
        json.field "bucket", directive.date || Karma::TimeSeries::Bucket.today.value
        json.field "value", directive.value || 1_u64
      when "batch_add"
        json.field "op", "series.batch_add"
        json.field "series", directive.tree_name
        json.field "granularity", "day"
        json.field "items", directive.items
      when "batch_set"
        json.field "op", "series.batch_set"
        json.field "series", directive.tree_name
        json.field "granularity", "day"
        json.field "items", directive.items
      when "batch_reset"
        json.field "op", "counter.batch_reset"
        json.field "series", directive.tree_name
        json.field "keys", directive.keys
      when "batch_delete_range"
        json.field "op", "counter.batch_delete_range"
        json.field "series", directive.tree_name
        json.field "keys", directive.keys
        write_range(json, directive)
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
      when "idempotency_prune"
        json.field "op", "idempotency.prune"
        json.field "before", directive.before_unix
        json.field "limit", directive.limit unless directive.limit.nil?
      when "delete"
        if directive.key
          json.field "op", "counter.delete_range"
          json.field "series", directive.tree_name
          json.field "key", directive.key
          write_range(json, directive)
        else
          json.field "op", "tree.delete_range"
          json.field "series", directive.tree_name
          write_range(json, directive)
        end
      when "reset"
        if directive.key
          json.field "op", "counter.reset"
          json.field "series", directive.tree_name
          json.field "key", directive.key
        else
          json.field "op", "tree.reset"
          json.field "series", directive.tree_name
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
