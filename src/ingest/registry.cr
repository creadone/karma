module Karma
  module Ingest
    @@streams = Hash(String, Stream).new

    def self.begin_stream(stream_id : String, mode : String, granularity : String?, begin_fingerprint : String)
      unless SUPPORTED_MODES.includes?(mode)
        raise Karma::Error.new("validation_error", "Unsupported ingest mode #{mode}")
      end

      if committed = Karma::Idempotency.committed_stream?(stream_id)
        unless committed.compatible_begin?(mode, granularity)
          raise Karma::Error.new("idempotency_conflict", "Ingest stream was already committed with different parameters")
        end

        return committed.to_status("already_committed")
      end

      if stream = @@streams[stream_id]?
        unless stream.mode == mode && stream.granularity == granularity && stream.begin_fingerprint == begin_fingerprint
          raise Karma::Error.new("idempotency_conflict", "Ingest stream already exists with different parameters")
        end

        return stream_status(stream)
      end

      stream = Stream.new(stream_id, mode, granularity, begin_fingerprint)
      @@streams[stream_id] = stream
      stream_status(stream)
    end

    def self.chunk_status(stream_id : String, chunk_seq : UInt64, fingerprint : String? = nil, series_name : String? = nil)
      if committed = Karma::Idempotency.committed_stream?(stream_id)
        raise Karma::Error.new("validation_error", "Field chunk_seq must be greater than 0") if chunk_seq == 0_u64
        unless fingerprint && series_name && committed.compatible_chunk?(chunk_seq, fingerprint, series_name)
          raise Karma::Error.new("idempotency_conflict", "Ingest stream was already committed with different chunks")
        end

        return {stream_id: stream_id, chunk_seq: chunk_seq, skipped: true, committed: true}
      end

      stream = validate_chunk!(stream_id, chunk_seq)

      if chunk_seq <= stream.last_chunk_seq
        if fingerprint && stream.chunk_fingerprints[chunk_seq]? != fingerprint
          raise Karma::Error.new("idempotency_conflict", "Ingest chunk was already used with different payload")
        end

        return {stream_id: stream.stream_id, chunk_seq: chunk_seq, skipped: true, committed: false}
      end

      unless chunk_seq == stream.last_chunk_seq + 1_u64
        raise Karma::Error.new("validation_error", "Field chunk_seq must be the next chunk")
      end

      {stream_id: stream.stream_id, chunk_seq: chunk_seq, skipped: false, committed: false}
    end

    def self.validate_chunk!(stream_id : String, chunk_seq : UInt64) : Stream
      if Karma::Idempotency.committed_stream?(stream_id)
        raise Karma::Error.new("validation_error", "Field chunk_seq must be greater than 0") if chunk_seq == 0_u64
        raise Karma::Error.new("idempotency_conflict", "Ingest stream was already committed")
      end

      stream = stream!(stream_id)
      raise Karma::Error.new("validation_error", "Field chunk_seq must be greater than 0") if chunk_seq == 0_u64
      return stream if chunk_seq <= stream.last_chunk_seq

      unless chunk_seq == stream.last_chunk_seq + 1_u64
        raise Karma::Error.new("validation_error", "Field chunk_seq must be the next chunk")
      end

      stream
    end

    def self.validate_stream_exists!(stream_id : String) : Stream
      stream!(stream_id)
    end

    def self.mark_chunk(stream_id : String, chunk_seq : UInt64, fingerprint : String)
      stream = stream!(stream_id)
      stream.last_chunk_seq = chunk_seq
      stream.chunk_fingerprints[chunk_seq] = fingerprint
      {stream_id: stream.stream_id, chunk_seq: chunk_seq, last_chunk_seq: stream.last_chunk_seq}
    end

    def self.bind_series!(stream : Stream, series_name : String) : Stream
      if existing = stream.series_name
        unless existing == series_name
          raise Karma::Error.new("validation_error", "Ingest stream is already bound to series #{existing}")
        end
      else
        stream.series_name = series_name
      end

      stream
    end

    def self.commit(stream_id : String, cluster)
      if committed = Karma::Idempotency.committed_stream?(stream_id)
        return committed.to_status("already_committed")
      end

      stream = stream!(stream_id)
      if stream.mode == "replace_series"
        series_name = stream.series_name || raise Karma::Error.new("validation_error", "Cannot commit empty replace_series stream")
        staged_tree = stream.staged_tree || CounterTree::Tree.new
        cluster.replace(series_name, staged_tree)
      end
      @@streams.delete(stream_id)
      committed = Karma::Idempotency.commit_stream(stream, stream.begin_fingerprint, stream.chunk_fingerprints)
      {stream_id: committed.stream_id, status: "committed", last_chunk_seq: committed.last_chunk_seq}
    end

    def self.abort(stream_id : String)
      stream = stream!(stream_id)
      @@streams.delete(stream_id)
      {stream_id: stream.stream_id, status: "aborted", last_chunk_seq: stream.last_chunk_seq}
    end

    private def self.reset_streams! : Nil
      @@streams.clear
    end

    private def self.active_stream_count : Int32
      @@streams.size
    end

    private def self.stream!(stream_id : String) : Stream
      @@streams[stream_id]? || raise Karma::Error.new("not_found", "Ingest stream \"#{stream_id}\" not found")
    end

    private def self.stream_status(stream : Stream)
      {
        stream_id:      stream.stream_id,
        mode:           stream.mode,
        series:         stream.series_name,
        granularity:    stream.granularity,
        status:         "active",
        last_chunk_seq: stream.last_chunk_seq,
      }
    end
  end
end
