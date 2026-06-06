module Karma
  module Commands
    module IngestChunk
      def self.call(directive, cluster)
        started_at = Time.monotonic
        stream_id = directive.stream_id.not_nil!
        chunk_seq = directive.chunk_seq.not_nil!
        fingerprint = Karma::Idempotency.fingerprint(directive)
        status = Karma::Ingest.chunk_status(stream_id, chunk_seq, fingerprint, directive.series_name)

        if status[:skipped]
          Karma::Ingest.record_chunk(applied: false, skipped: true, item_count: 0, latency_ms: elapsed_ms(started_at))
          return {
            stream_id: stream_id,
            chunk_seq: chunk_seq,
            skipped:   true,
            committed: status[:committed],
            applied:   0,
            total:     0_u64,
          }
        end

        series = directive.series
        items = directive.items.not_nil!
        stream = Karma::Ingest.bind_series!(
          Karma::Ingest.validate_stream_exists!(stream_id),
          series.name
        )

        result = apply_items(stream, cluster, series.name, items)
        Karma::Ingest.mark_chunk(stream_id, chunk_seq, fingerprint)
        Karma::Ingest.record_chunk(applied: true, skipped: false, item_count: result[:applied], latency_ms: elapsed_ms(started_at))

        {
          stream_id: stream_id,
          chunk_seq: chunk_seq,
          skipped:   false,
          applied:   result[:applied],
          total:     result[:total],
        }
      end

      private def self.elapsed_ms(started_at : Time::Span) : Float64
        (Time.monotonic - started_at).total_milliseconds
      end

      private def self.apply_items(stream : Karma::Ingest::Stream, cluster, series_name : String, items : Array(Array(UInt64)))
        case stream.mode
        when "add"
          cluster.pick(series_name) do |tree|
            return Commands::BatchAdd.apply(tree, items)
          end
        when "set"
          cluster.pick(series_name) do |tree|
            return Commands::BatchSet.apply(tree, items)
          end
        when "replace_series"
          staged_tree = stream.staged_tree ||= Karma::BucketedCounter::Store.new
          return Commands::BatchSet.apply(staged_tree, items)
        else
          raise Karma::Error.new("validation_error", "Unsupported ingest mode #{stream.mode}")
        end
      end
    end
  end
end
