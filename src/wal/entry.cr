require "json"

module Karma
  module Wal
    struct Entry
      getter lsn : UInt64
      getter entry : JSON::Any

      def initialize(@lsn : UInt64, @entry : JSON::Any)
      end

      def to_response
        {
          lsn:   lsn,
          entry: entry,
        }
      end
    end

    def self.entries_after(after_lsn : UInt64, limit : Int32 = 1_000, dump_dir = Karma.config.dump_dir) : Array(Entry)
      raise Karma::Error.new("validation_error", "Field limit must be greater than 0") if limit <= 0
      raise Karma::Error.new("validation_error", "Field limit exceeds max size") if limit > 10_000

      wal_path = path(dump_dir)
      return [] of Entry unless File.exists?(wal_path)

      entries = [] of Entry
      File.each_line(wal_path) do |line|
        next if line.blank?
        wal_entry = parse_entry(line)
        next if wal_entry.nil?
        next unless wal_entry.lsn > after_lsn

        entries << wal_entry
        break if entries.size >= limit
      end
      entries
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
