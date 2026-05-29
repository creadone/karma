require "digest/sha256"

module Karma
  module Idempotency
    def self.fingerprint(directive) : String
      Digest::SHA256.hexdigest(canonical_payload(directive))
    end

    private def self.canonical_payload(directive) : String
      String.build do |io|
        field(io, "command", directive.command)
        case directive.command
        when "increment", "decrement"
          field(io, "series", directive.series_name)
          field(io, "key", directive.key_value)
          field(io, "bucket", directive.write_bucket.value)
          field(io, "value", directive.write_value)
        when "batch_add", "batch_set"
          field(io, "series", directive.series_name)
          write_items(io, directive.items.not_nil!)
        when "batch_reset"
          field(io, "series", directive.series_name)
          write_keys(io, directive.keys.not_nil!)
        when "batch_delete_range"
          field(io, "series", directive.series_name)
          write_keys(io, directive.keys.not_nil!)
          field(io, "range_from", directive.bucket_from.value)
          field(io, "range_to", directive.bucket_to.value)
        when "delete"
          field(io, "series", directive.series_name)
          field(io, "key", directive.key)
          field(io, "range_from", directive.bucket_from.value)
          field(io, "range_to", directive.bucket_to.value)
        when "reset"
          field(io, "series", directive.series_name)
          field(io, "key", directive.key)
        when "ingest_begin"
          field(io, "stream_id", directive.stream_id.not_nil!)
          field(io, "mode", directive.mode.not_nil!)
          field(io, "granularity", directive.granularity)
        when "ingest_chunk"
          field(io, "stream_id", directive.stream_id.not_nil!)
          field(io, "series", directive.series_name)
          field(io, "chunk_seq", directive.chunk_seq.not_nil!)
          write_items(io, directive.items.not_nil!)
        when "ingest_commit", "ingest_abort"
          field(io, "stream_id", directive.stream_id.not_nil!)
        end
      end
    end

    private def self.write_items(io : IO, items : Array(Array(UInt64))) : Nil
      field(io, "items_count", items.size)
      items.each do |item|
        field(io, "item_key", item[0])
        field(io, "item_bucket", item[1])
        field(io, "item_value", item[2])
      end
    end

    private def self.write_keys(io : IO, keys : Array(UInt64)) : Nil
      field(io, "keys_count", keys.size)
      keys.each { |key| field(io, "key_value", key) }
    end

    private def self.field(io : IO, name : String, value : String?) : Nil
      if value
        io << name << ":s:" << value.bytesize << ":" << value << "\n"
      else
        io << name << ":n\n"
      end
    end

    private def self.field(io : IO, name : String, value : UInt64?) : Nil
      if value
        io << name << ":u:" << value << "\n"
      else
        io << name << ":n\n"
      end
    end

    private def self.field(io : IO, name : String, value : Int32) : Nil
      io << name << ":i:" << value << "\n"
    end
  end
end
