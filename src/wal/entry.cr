require "json"

module Karma
  module Wal
    struct Entry
      getter lsn : UInt64
      getter entry : JSON::Any

      def initialize(@lsn : UInt64, @entry : JSON::Any)
      end

      def self.from_response(object : JSON::Any) : Entry
        hash = object.as_h
        lsn = hash["lsn"].as_i64.to_u64
        entry = hash["entry"]

        new(lsn, entry)
      end

      def to_response
        {
          lsn:   lsn,
          entry: entry,
        }
      end

      def response_bytes : Int32
        to_response.to_json.bytesize
      end
    end

    struct EntriesPage
      getter entries : Array(Entry)
      getter bytes : Int32
      getter truncated_by_bytes : Bool

      def initialize(@entries : Array(Entry), @bytes : Int32, @truncated_by_bytes : Bool)
      end
    end

    def self.entries_after(after_lsn : UInt64, limit : Int32 = 1_000, dump_dir = Karma.config.dump_dir) : Array(Entry)
      entries_page_after(after_lsn, limit, dump_dir).entries
    end

    def self.entries_page_after(after_lsn : UInt64, limit : Int32 = 1_000, dump_dir = Karma.config.dump_dir, max_bytes : Int32? = nil) : EntriesPage
      raise Karma::Error.new("validation_error", "Field limit must be greater than 0") if limit <= 0
      raise Karma::Error.new("validation_error", "Field limit exceeds max size") if limit > 10_000
      raise Karma::Error.new("validation_error", "Field max_bytes must be greater than 0") if max_bytes && max_bytes <= 0

      wal_path = path(dump_dir)
      return EntriesPage.new([] of Entry, 0, false) unless File.exists?(wal_path)

      entries = [] of Entry
      bytes = 0
      truncated_by_bytes = false
      File.each_line(wal_path) do |line|
        next if line.blank?
        wal_entry = parse_entry(line)
        next if wal_entry.nil?
        next unless wal_entry.lsn > after_lsn

        entry_bytes = wal_entry.response_bytes
        if max_bytes && bytes + entry_bytes > max_bytes
          truncated_by_bytes = true
          break unless entries.empty?

          raise Karma::Error.new(
            "response_too_large",
            "Single WAL entry #{wal_entry.lsn} exceeds replication response byte budget"
          )
        end

        entries << wal_entry
        bytes += entry_bytes
        break if entries.size >= limit
      end
      EntriesPage.new(entries, bytes, truncated_by_bytes)
    end

    private def self.parse_entry(line : String) : Entry?
      object = JSON.parse(line).as_h
      lsn = object["lsn"]?.try(&.as_i64?.try(&.to_u64))
      entry = object["entry"]?
      return nil if lsn.nil? || entry.nil?

      Entry.new(lsn, entry)
    end
  end
end
