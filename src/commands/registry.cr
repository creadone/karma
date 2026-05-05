module Karma
  module Commands
    COMMANDS = {
      "trees"                 => Commands::Trees,
      "create"                => Commands::Create,
      "drop"                  => Commands::Drop,
      "dump"                  => Commands::Dump,
      "dump_all"              => Commands::DumpAll,
      "dumps"                 => Commands::Dumps,
      "load"                  => Commands::Load,
      "increment"             => Commands::Increment,
      "decrement"             => Commands::Decrement,
      "sum"                   => Commands::Sum,
      "batch_sum"             => Commands::BatchSum,
      "batch_add"             => Commands::BatchAdd,
      "delete_before"         => Commands::DeleteBefore,
      "compact"               => Commands::Compact,
      "find"                  => Commands::Find,
      "reset"                 => Commands::Reset,
      "delete"                => Commands::Delete,
      "health"                => Commands::Health,
      "stats"                 => Commands::Stats,
      "metrics"               => Commands::Metrics,
      "verify"                => Commands::Verify,
      "reconciliation_report" => Commands::ReconciliationReport,
      "recovery_checkpoint"   => Commands::RecoveryCheckpoint,
      "recovery_status"       => Commands::RecoveryStatus,
      "replication_status"    => Commands::ReplicationStatus,
      "replication_entries"   => Commands::ReplicationEntries,
      "ping"                  => Commands::Ping,
      "tree_info"             => Commands::TreeInfo,
      "tree_keys"             => Commands::TreeKeys,
      "tree_summary"          => Commands::TreeSummary,
      "tree_top"              => Commands::TreeTop,
      "snapshot_info"         => Commands::SnapshotInfo,
      "snapshot_fetch"        => Commands::SnapshotFetch,
      "snapshot_fetch_chunk"  => Commands::SnapshotFetchChunk,
      "ingest_begin"          => Commands::IngestBegin,
      "ingest_chunk"          => Commands::IngestChunk,
      "ingest_commit"         => Commands::IngestCommit,
      "ingest_abort"          => Commands::IngestAbort,
    }

    READ_ONLY_COMMANDS = %w[
      ping
      trees
      dumps
      health
      stats
      metrics
      verify
      sum
      batch_sum
      find
      tree_info
      tree_keys
      tree_summary
      tree_top
      snapshot_info
      snapshot_fetch
      snapshot_fetch_chunk
      recovery_status
      replication_status
      replication_entries
    ]

    MUTATING_COMMANDS = %w[
      create
      drop
      increment
      decrement
      delete
      reset
      batch_add
      delete_before
      compact
      ingest_begin
      ingest_chunk
      ingest_commit
      ingest_abort
      recovery_checkpoint
    ]

    def self.known?(directive : Directive) : Bool
      COMMANDS.has_key?(directive.command)
    end

    def self.read_only?(directive : Directive) : Bool
      READ_ONLY_COMMANDS.includes?(directive.command)
    end

    def self.mutating?(directive : Directive) : Bool
      MUTATING_COMMANDS.includes?(directive.command)
    end
  end
end
