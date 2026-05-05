require "json"

module Karma
  module Commands
    private def self.parse_v2(object : Hash(String, JSON::Any)) : Directive
      op = object["op"]?.try(&.as_s?) || raise Karma::Error.new("validation_error", "Field op is required")
      token = object["token"]?.try(&.as_s?)

      case op
      when "system.ping"
        Directive.new("ping", token: token, protocol_version: 2_u32)
      when "system.health"
        Directive.new("health", token: token, protocol_version: 2_u32)
      when "system.stats"
        Directive.new("stats", token: token, protocol_version: 2_u32)
      when "system.metrics"
        Directive.new("metrics", token: token, protocol_version: 2_u32)
      when "reconciliation.report"
        Directive.new("reconciliation_report", checked_points: checked_points_from(object), mismatch_count: mismatch_count_from(object), absolute_drift: absolute_drift_from(object), max_abs_delta: max_abs_delta_from(object), token: token, protocol_version: 2_u32)
      when "recovery.checkpoint"
        Directive.new("recovery_checkpoint", source: source_from(object), source_offset: source_offset_from(object), event_id: event_id_from(object), token: token, protocol_version: 2_u32)
      when "recovery.status"
        Directive.new("recovery_status", source: optional_source_from(object), token: token, protocol_version: 2_u32)
      when "snapshot.info"
        Directive.new("snapshot_info", token: token, protocol_version: 2_u32)
      when "tree.create"
        Directive.new("create", tree_name: tree_or_series(object), token: token, protocol_version: 2_u32)
      when "tree.drop"
        Directive.new("drop", tree_name: tree_or_series(object), token: token, protocol_version: 2_u32)
      when "tree.list"
        Directive.new("trees", token: token, protocol_version: 2_u32)
      when "tree.reset"
        Directive.new("reset", tree_name: tree_or_series(object), token: token, protocol_version: 2_u32)
      when "tree.info"
        Directive.new("tree_info", tree_name: tree_or_series(object), token: token, protocol_version: 2_u32)
      when "tree.keys"
        Directive.new("tree_keys", tree_name: tree_or_series(object), limit: limit_from(object), cursor: cursor_from(object), token: token, protocol_version: 2_u32)
      when "tree.summary"
        range = optional_range_from(object)
        Directive.new("tree_summary", tree_name: tree_or_series(object), time_from: range.try(&.from.value), time_to: range.try(&.to.value), token: token, protocol_version: 2_u32)
      when "tree.top"
        range = optional_range_from(object)
        Directive.new("tree_top", tree_name: tree_or_series(object), limit: limit_from(object), time_from: range.try(&.from.value), time_to: range.try(&.to.value), token: token, protocol_version: 2_u32)
      when "tree.series"
        range = range_from(object)
        Directive.new("find", tree_name: tree_or_series(object), time_from: range.from.value, time_to: range.to.value, token: token, protocol_version: 2_u32)
      when "tree.delete_range"
        range = range_from(object)
        Directive.new("delete", tree_name: tree_or_series(object), time_from: range.from.value, time_to: range.to.value, token: token, protocol_version: 2_u32)
      when "system.compact"
        Directive.new("compact", token: token, protocol_version: 2_u32)
      when "series.compact", "tree.compact"
        Directive.new("compact", tree_name: tree_or_series(object), token: token, protocol_version: 2_u32)
      when "counter.increment", "series.increment"
        Directive.new("increment", tree_name: tree_or_series(object), key: key_from(object), date: date_or_bucket(object), value: value_from(object), token: token, protocol_version: 2_u32)
      when "counter.batch_increment", "series.batch_add"
        Directive.new("batch_add", tree_name: tree_or_series(object), items: items_from(object), token: token, protocol_version: 2_u32)
      when "counter.decrement"
        Directive.new("decrement", tree_name: tree_or_series(object), key: key_from(object), date: date_or_bucket(object), value: value_from(object), token: token, protocol_version: 2_u32)
      when "counter.sum", "series.sum"
        range = optional_range_from(object)
        Directive.new("sum", tree_name: tree_or_series(object), key: key_from(object), time_from: range.try(&.from.value), time_to: range.try(&.to.value), token: token, protocol_version: 2_u32)
      when "counter.batch_sum", "series.batch_sum"
        range = optional_range_from(object)
        Directive.new("batch_sum", tree_name: tree_or_series(object), keys: keys_from(object), time_from: range.try(&.from.value), time_to: range.try(&.to.value), token: token, protocol_version: 2_u32)
      when "counter.series", "series.points"
        range = range_from(object)
        Directive.new("find", tree_name: tree_or_series(object), key: key_from(object), time_from: range.from.value, time_to: range.to.value, token: token, protocol_version: 2_u32)
      when "counter.delete_range"
        range = range_from(object)
        Directive.new("delete", tree_name: tree_or_series(object), key: key_from(object), time_from: range.from.value, time_to: range.to.value, token: token, protocol_version: 2_u32)
      when "series.delete_before", "tree.delete_before"
        Directive.new("delete_before", tree_name: tree_or_series(object), date: before_from(object), token: token, protocol_version: 2_u32)
      when "counter.reset"
        Directive.new("reset", tree_name: tree_or_series(object), key: key_from(object), token: token, protocol_version: 2_u32)
      when "snapshot.create"
        Directive.new("dump", tree_name: tree_or_series(object), token: token, protocol_version: 2_u32)
      when "snapshot.create_all"
        Directive.new("dump_all", token: token, protocol_version: 2_u32)
      when "snapshot.list"
        Directive.new("dumps", token: token, protocol_version: 2_u32)
      when "snapshot.load"
        file = object["file"]?.try(&.as_s?) || raise Karma::Error.new("validation_error", "Field file is required")
        Directive.new("load", tree_name: file, token: token, protocol_version: 2_u32)
      when "snapshot.verify"
        Directive.new("verify", token: token, protocol_version: 2_u32)
      when "ingest.begin"
        Directive.new("ingest_begin", stream_id: stream_id_from(object), mode: mode_from(object), granularity: granularity_from(object), token: token, protocol_version: 2_u32)
      when "ingest.chunk"
        Directive.new("ingest_chunk", tree_name: tree_or_series(object), stream_id: stream_id_from(object), chunk_seq: chunk_seq_from(object), items: items_from(object), token: token, protocol_version: 2_u32)
      when "ingest.commit"
        Directive.new("ingest_commit", stream_id: stream_id_from(object), token: token, protocol_version: 2_u32)
      when "ingest.abort"
        Directive.new("ingest_abort", stream_id: stream_id_from(object), token: token, protocol_version: 2_u32)
      else
        raise Karma::Error.new("unknown_command", "Unknown op #{op}")
      end
    end
  end
end
