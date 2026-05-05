module Karma
  module Commands
    private def self.validate(directive : Directive) : Nil
      case directive.command
      when "ping", "trees", "dumps", "dump_all", "health", "stats", "metrics", "verify"
      when "snapshot_info"
      when "create", "drop", "dump", "load", "reset"
        require_tree_name(directive)
      when "tree_info"
        require_tree_name(directive)
      when "tree_keys"
        require_tree_name(directive)
        require_limit(directive, default: 100, max: 10_000)
      when "tree_summary"
        require_tree_name(directive)
        require_complete_range(directive) if directive.time_from || directive.time_to
      when "tree_top"
        require_tree_name(directive)
        require_limit(directive, default: 50, max: 1_000)
        require_complete_range(directive) if directive.time_from || directive.time_to
      when "increment", "decrement"
        require_tree_name(directive)
        require_key(directive)
        require_positive_value(directive) unless directive.value.nil?
      when "sum"
        require_tree_name(directive)
        require_key(directive)
        require_complete_range(directive) if directive.time_from || directive.time_to
      when "batch_sum"
        require_tree_name(directive)
        require_keys(directive)
        require_complete_range(directive) if directive.time_from || directive.time_to
      when "batch_add"
        require_tree_name(directive)
        require_items(directive)
      when "delete_before"
        require_tree_name(directive)
        require_date(directive)
      when "compact"
      when "ingest_begin"
        require_stream_id(directive)
        require_mode(directive)
      when "ingest_chunk"
        require_stream_id(directive)
        require_tree_name(directive)
        require_chunk_seq(directive)
        require_ingest_items(directive)
      when "ingest_commit", "ingest_abort"
        require_stream_id(directive)
        Karma::Ingest.validate_stream_exists!(directive.stream_id.not_nil!)
      when "reconciliation_report"
        require_reconciliation_report(directive)
      when "find", "delete"
        require_tree_name(directive)
        require_complete_range(directive)
      else
        raise Karma::Error.new("unknown_command", "Unknown command #{directive.command}")
      end
    end
  end
end
