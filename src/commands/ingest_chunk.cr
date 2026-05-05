module Karma
  module Commands
    module IngestChunk
      def self.call(directive, cluster)
        started_at = Time.monotonic
        stream_id = directive.stream_id.not_nil!
        chunk_seq = directive.chunk_seq.not_nil!
        status = Karma::Ingest.chunk_status(stream_id, chunk_seq)

        if status[:skipped]
          Karma::Ingest.record_chunk(applied: false, skipped: true, item_count: 0, latency_ms: elapsed_ms(started_at))
          return {
            stream_id: stream_id,
            chunk_seq: chunk_seq,
            skipped:   true,
            applied:   0,
            total:     0_u64,
          }
        end

        series = directive.series
        items = directive.items.not_nil!

        cluster.pick(series.name) do |tree|
          result = Commands::BatchAdd.apply(tree, items)
          Karma::Ingest.mark_chunk(stream_id, chunk_seq)
          Karma::Ingest.record_chunk(applied: true, skipped: false, item_count: result[:applied], latency_ms: elapsed_ms(started_at))

          return {
            stream_id: stream_id,
            chunk_seq: chunk_seq,
            skipped:   false,
            applied:   result[:applied],
            total:     result[:total],
          }
        end
      end

      private def self.elapsed_ms(started_at : Time::Span) : Float64
        (Time.monotonic - started_at).total_milliseconds
      end
    end
  end
end
