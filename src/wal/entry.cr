require "json"

module Karma
  module Wal
    @@entry_index_mutex = Mutex.new
    SEGMENT_INDEX_HEADER     = "KARMA_WAL_INDEX_V1"
    ENTRY_OFFSET_CACHE_FILES = 8
    @@entry_file_offsets = {} of String => Tuple(Int64, Array(Tuple(UInt64, Int64)))
    @@entry_file_offset_order = [] of String
    @@active_index_path : String?
    @@active_index_size = 0_i64
    @@active_index_complete = false
    @@active_index_offsets = [] of Tuple(UInt64, Int64)

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

      index_snapshot = entry_start_position(after_lsn, dump_dir)
      return EntriesPage.new([] of Entry, 0, false) if index_snapshot.nil?
      wal_files = index_snapshot[:files]
      file_index = index_snapshot[:file_index]
      start_offset = index_snapshot[:offset]

      entries = [] of Entry
      bytes = 0
      truncated_by_bytes = false
      while file_index < wal_files.size
        File.open(wal_files[file_index]) do |io|
          io.seek(file_index == index_snapshot[:file_index] ? start_offset : 0_i64)
          while line = io.gets
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
        end
        break if truncated_by_bytes || entries.size >= limit

        file_index += 1
      end
      EntriesPage.new(entries, bytes, truncated_by_bytes)
    end

    private def self.reset_entry_index(dump_dir : String? = nil) : Nil
      @@entry_index_mutex.synchronize do
        @@entry_file_offsets = {} of String => Tuple(Int64, Array(Tuple(UInt64, Int64)))
        @@entry_file_offset_order = [] of String
        reset_active_entry_index_locked
      end
    end

    private def self.record_entry_offset(dump_dir : String, lsn : UInt64, offset : Int64, size : Int64) : Nil
      wal_path = path(dump_dir)
      @@entry_index_mutex.synchronize do
        record_active_entry_offset_locked(wal_path, lsn, offset, size)

        cached = @@entry_file_offsets[wal_path]?
        if cached && cached[0] == offset
          cached[1] << {lsn, offset}
          store_entry_offsets_locked(wal_path, size, cached[1])
        elsif cached
          delete_entry_offsets_locked(wal_path)
        end
      end
    end

    private def self.record_active_entry_offset_locked(wal_path : String, lsn : UInt64, offset : Int64, size : Int64) : Nil
      if offset == 0_i64
        @@active_index_path = wal_path
        @@active_index_size = size
        @@active_index_complete = true
        @@active_index_offsets = [{lsn, offset}]
        return
      end

      if @@active_index_complete && @@active_index_path == wal_path && @@active_index_size == offset
        @@active_index_offsets << {lsn, offset}
        @@active_index_size = size
      else
        @@active_index_path = wal_path
        @@active_index_size = size
        @@active_index_complete = false
        @@active_index_offsets = [] of Tuple(UInt64, Int64)
      end
    end

    private def self.reset_active_entry_index_locked : Nil
      @@active_index_path = nil
      @@active_index_size = 0_i64
      @@active_index_complete = false
      @@active_index_offsets = [] of Tuple(UInt64, Int64)
    end

    private def self.active_entry_offsets(file_path : String, size : Int64) : Array(Tuple(UInt64, Int64))?
      @@entry_index_mutex.synchronize do
        if @@active_index_complete && @@active_index_path == file_path && @@active_index_size == size
          @@active_index_offsets.dup
        end
      end
    end

    private def self.entry_start_position(after_lsn : UInt64, dump_dir : String)
      wal_files = paths(dump_dir)
      return nil if wal_files.empty?

      file_index = start_file_index(wal_files, after_lsn)
      while file_index < wal_files.size
        wal_path = wal_files[file_index]
        size = File.size(wal_path).to_i64
        offset = entry_offset_after(wal_path, size, after_lsn)
        if offset
          return {
            files:      wal_files,
            file_index: file_index,
            offset:     offset,
          }
        end

        file_index += 1
      end

      nil
    end

    private def self.start_file_index(wal_files : Array(String), after_lsn : UInt64) : Int32
      left = 0
      right = wal_files.size
      while left < right
        mid = (left + right) // 2
        first = file_first_lsn(wal_files[mid])
        if first && first <= after_lsn
          left = mid + 1
        else
          right = mid
        end
      end

      left > 0 ? left - 1 : 0
    end

    private def self.file_first_lsn(file_path : String) : UInt64?
      segment_file?(file_path) ? segment_first_lsn(file_path) : first_lsn(file_path)
    end

    private def self.entry_offset_after(file_path : String, size : Int64, after_lsn : UInt64) : Int64?
      offsets = cached_entry_offsets?(file_path, size)
      if offsets
        offset = first_offset_after(offsets, after_lsn)
        return offset if offset && entry_offset_boundary?(file_path, offset)
      end

      unless segment_file?(file_path)
        complete, offset = binary_search_entry_offset_after(file_path, size, after_lsn)
        return nil if complete && offset.nil?
        return offset if offset && entry_offset_boundary?(file_path, offset)
      end

      offsets = cached_entry_offsets(file_path, size)
      offset = first_offset_after(offsets, after_lsn)
      unless offset.nil? || entry_offset_boundary?(file_path, offset)
        offsets = scan_cached_entry_offsets(file_path, size)
        offset = first_offset_after(offsets, after_lsn)
      end

      offset if offset && entry_offset_boundary?(file_path, offset)
    end

    private def self.cached_entry_offsets?(file_path : String, size : Int64) : Array(Tuple(UInt64, Int64))?
      @@entry_index_mutex.synchronize do
        cached = @@entry_file_offsets[file_path]?
        if cached && cached[0] == size
          touch_entry_offsets_locked(file_path)
          return cached[1].dup
        end

        delete_entry_offsets_locked(file_path) if cached
      end
    end

    private def self.cached_entry_offsets(file_path : String, size : Int64) : Array(Tuple(UInt64, Int64))
      cached = cached_entry_offsets?(file_path, size)
      return cached if cached

      offsets = entry_offsets_for_file(file_path, size)
      @@entry_index_mutex.synchronize do
        store_entry_offsets_locked(file_path, size, offsets)
      end
      offsets.dup
    end

    private def self.scan_cached_entry_offsets(file_path : String, size : Int64) : Array(Tuple(UInt64, Int64))
      offsets = scan_entry_offsets(file_path, size)
      @@entry_index_mutex.synchronize do
        store_entry_offsets_locked(file_path, size, offsets)
      end
      offsets.dup
    end

    private def self.store_entry_offsets_locked(file_path : String, size : Int64, offsets : Array(Tuple(UInt64, Int64))) : Nil
      @@entry_file_offsets[file_path] = {size, offsets}
      touch_entry_offsets_locked(file_path)
      prune_entry_offsets_locked
    end

    private def self.delete_entry_offsets_locked(file_path : String) : Nil
      @@entry_file_offsets.delete(file_path)
      @@entry_file_offset_order.delete(file_path)
    end

    private def self.touch_entry_offsets_locked(file_path : String) : Nil
      @@entry_file_offset_order.delete(file_path)
      @@entry_file_offset_order << file_path
    end

    private def self.prune_entry_offsets_locked : Nil
      while @@entry_file_offset_order.size > ENTRY_OFFSET_CACHE_FILES
        file_path = @@entry_file_offset_order.shift
        @@entry_file_offsets.delete(file_path)
      end
    end

    private def self.first_offset_after(offsets : Array(Tuple(UInt64, Int64)), after_lsn : UInt64) : Int64?
      left = 0
      right = offsets.size
      while left < right
        mid = (left + right) // 2
        if offsets[mid][0] > after_lsn
          right = mid
        else
          left = mid + 1
        end
      end

      left < offsets.size ? offsets[left][1] : nil
    end

    private def self.binary_search_entry_offset_after(file_path : String, size : Int64, after_lsn : UInt64) : Tuple(Bool, Int64?)
      return {true, nil} if size <= 0

      File.open(file_path) do |io|
        first = lsn_at_offset(io, 0_i64)
        return {false, nil} if first.nil?
        return {true, 0_i64} if first > after_lsn

        left = 0_i64
        right = size
        while left < right
          mid = (left + right) // 2
          sample_offset = line_start_at_or_after(io, mid, size)
          if sample_offset.nil?
            right = mid
            next
          end

          lsn = lsn_at_offset(io, sample_offset)
          return {false, nil} if lsn.nil?

          if lsn > after_lsn
            right = mid
          else
            left = sample_offset + 1
          end
        end

        {true, scan_offset_after(io, line_start_at_or_before(io, left, size), after_lsn)}
      end
    rescue IO::Error | JSON::ParseException
      {false, nil}
    end

    private def self.line_start_at_or_after(io : File, offset : Int64, size : Int64) : Int64?
      return 0_i64 if offset <= 0
      return nil if offset >= size

      io.seek(offset - 1)
      return offset if io.read_byte == '\n'.ord

      io.seek(offset)
      while byte = io.read_byte
        if byte == '\n'.ord
          position = io.pos.to_i64
          return position < size ? position : nil
        end
      end
    end

    private def self.line_start_at_or_before(io : File, offset : Int64, size : Int64) : Int64
      return 0_i64 if offset <= 0 || size <= 0

      cursor = offset >= size ? size - 1 : offset
      return 0_i64 if cursor <= 0

      io.seek(cursor - 1)
      return cursor if cursor > 0 && io.read_byte == '\n'.ord

      while cursor > 0
        cursor -= 1
        io.seek(cursor)
        return cursor + 1 if io.read_byte == '\n'.ord
      end

      0_i64
    end

    private def self.lsn_at_offset(io : File, offset : Int64) : UInt64?
      io.seek(offset)
      line = io.gets
      return nil if line.nil? || line.blank?

      extract_lsn(line)
    rescue JSON::ParseException
      nil
    end

    private def self.scan_offset_after(io : File, offset : Int64, after_lsn : UInt64) : Int64?
      io.seek(offset)
      loop do
        current_offset = io.pos.to_i64
        line = io.gets
        break if line.nil?
        next if line.blank?

        lsn = extract_lsn(line)
        return current_offset if lsn && lsn > after_lsn
      end
    end

    private def self.entry_offset_boundary?(file_path : String, offset : Int64) : Bool
      return true if offset == 0_i64

      File.open(file_path) do |io|
        io.seek(offset - 1)
        io.read_byte == '\n'.ord
      end
    rescue
      false
    end

    private def self.entry_offsets_for_file(file_path : String, size : Int64) : Array(Tuple(UInt64, Int64))
      if segment_file?(file_path)
        load_segment_index(file_path, size) || scan_entry_offsets(file_path, size)
      else
        scan_entry_offsets(file_path, size)
      end
    end

    private def self.scan_entry_offsets(file_path : String, size : Int64) : Array(Tuple(UInt64, Int64))
      offsets = [] of Tuple(UInt64, Int64)
      File.open(file_path) do |io|
        loop do
          offset = io.pos.to_i64
          break if offset >= size

          line = io.gets
          break if line.nil?
          next if line.blank?

          lsn = extract_lsn(line)
          next if lsn.nil?

          offsets << {lsn, offset}
        end
      end
      offsets
    end

    private def self.load_segment_index(file_path : String, size : Int64) : Array(Tuple(UInt64, Int64))?
      index_path = segment_index_path(file_path)
      return nil unless File.exists?(index_path)

      lines = File.read_lines(index_path)
      return nil if lines.empty?
      return nil unless lines.first == "#{SEGMENT_INDEX_HEADER} size=#{size}"

      offsets = [] of Tuple(UInt64, Int64)
      lines.each_with_index do |line, index|
        next if index == 0
        next if line.blank?

        parts = line.split(' ', remove_empty: true)
        return nil unless parts.size == 2

        lsn = parts[0].to_u64
        offset = parts[1].to_i64
        previous = offsets.last?
        return nil if offset < 0 || offset >= size
        return nil if offsets.empty? && offset != 0_i64
        return nil if previous && (lsn <= previous[0] || offset <= previous[1])

        offsets << {lsn, offset}
      end
      offsets
    rescue ArgumentError | IO::Error
      nil
    end

    private def self.write_segment_index(file_path : String, offsets : Array(Tuple(UInt64, Int64))? = nil) : Nil
      size = File.size(file_path).to_i64
      offsets ||= scan_entry_offsets(file_path, size)
      index_path = segment_index_path(file_path)
      temp_path = "#{index_path}.#{Process.pid}.tmp"

      File.open(temp_path, "w") do |io|
        io.puts "#{SEGMENT_INDEX_HEADER} size=#{size}"
        offsets.each do |offset|
          io << offset[0] << ' ' << offset[1] << '\n'
        end
        io.flush
      end
      File.rename(temp_path, index_path)
    ensure
      File.delete(temp_path) if temp_path && File.exists?(temp_path)
    end

    private def self.segment_file?(file_path : String) : Bool
      file_path.ends_with?(SEGMENT_EXTENSION)
    end

    private def self.extract_lsn(line : String) : UInt64?
      extract_compact_lsn(line) || parse_lsn(line)
    end

    private def self.first_lsn(file_path : String) : UInt64?
      return nil unless File.exists?(file_path)

      File.each_line(file_path) do |line|
        next if line.blank?

        return extract_lsn(line)
      end
    end

    private def self.extract_compact_lsn(line : String) : UInt64?
      prefix = "{\"v\":2,\"lsn\":"
      return nil unless line.starts_with?(prefix)

      index = prefix.bytesize
      return nil if index >= line.bytesize

      lsn = 0_u64
      started = false
      while index < line.bytesize
        byte = line.byte_at(index)
        break if byte == ','.ord
        return nil unless byte >= '0'.ord && byte <= '9'.ord

        started = true
        lsn = lsn * 10 + (byte - '0'.ord).to_u64
        index += 1
      end

      return nil unless started
      return nil unless index < line.bytesize && line.byte_at(index) == ','.ord

      lsn
    end

    private def self.parse_lsn(line : String) : UInt64?
      object = JSON.parse(line).as_h
      object["lsn"]?.try(&.as_i64?.try(&.to_u64))
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
