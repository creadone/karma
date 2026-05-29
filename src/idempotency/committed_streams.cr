module Karma
  module Idempotency
    @@committed_streams = Hash(String, CommittedStream).new

    def self.committed_stream?(stream_id : String) : CommittedStream?
      @@committed_streams[stream_id]?
    end

    def self.commit_stream(stream, begin_fingerprint : String, chunk_fingerprints : Hash(UInt64, String)) : CommittedStream
      record = CommittedStream.new(
        stream.stream_id,
        stream.mode,
        stream.granularity,
        stream.series_name,
        stream.last_chunk_seq,
        begin_fingerprint,
        chunk_fingerprints.dup,
        Time.utc.to_unix
      )
      @@committed_streams[record.stream_id] = record
      record
    end

    def self.replace_committed_streams(records : Array(CommittedStream)) : Nil
      @@committed_streams.clear
      records.each { |record| @@committed_streams[record.stream_id] = record }
    end

    def self.committed_streams : Array(CommittedStream)
      @@committed_streams.values
    end

    def self.committed_stream_count : Int32
      @@committed_streams.size
    end

    private def self.reset_committed_streams! : Nil
      @@committed_streams.clear
    end
  end
end
