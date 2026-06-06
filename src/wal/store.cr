module Karma
  module Wal
    def self.append(directive : Commands::Directive) : Bool
      return true unless enabled?

      dump_dir = File.expand_path(Karma.config.dump_dir)
      Dir.mkdir_p(dump_dir) unless Dir.exists?(dump_dir)

      with_next_lsn(dump_dir) do |lsn|
        io = wal_io(dump_dir)
        io.seek(0, IO::Seek::End)
        offset = io.pos.to_i64
        io.puts serialize(directive, lsn)
        io.flush
        io.fsync if fsync?
        record_entry_offset(dump_dir, lsn, offset, io.pos.to_i64)
      end

      true
    end

    def self.truncate : Bool
      return true unless enabled?

      dump_dir = File.expand_path(Karma.config.dump_dir)
      Dir.mkdir_p(dump_dir) unless Dir.exists?(dump_dir)
      close_wal_io(dump_dir)
      reset_paths_cache(dump_dir)
      reset_entry_index(dump_dir)
      segment_paths(dump_dir).each do |segment_path|
        index_path = segment_index_path(segment_path)
        File.delete(index_path) if File.exists?(index_path)
        File.delete(segment_path)
      end

      File.open(path(dump_dir), "w") do |io|
        io.flush
        io.fsync if fsync?
      end
      reset_paths_cache(dump_dir)
      Karma::Log.info("wal.truncate", "path=#{path(dump_dir)}")

      true
    end

    private def self.rotate_wal_if_needed(dump_dir : String) : Nil
      segment_bytes = Karma.config.wal_segment_bytes
      return if segment_bytes <= 0

      wal_path = path(dump_dir)
      return unless File.exists?(wal_path)
      return if File.size(wal_path) < segment_bytes

      first_lsn = first_lsn(wal_path)
      return if first_lsn.nil?

      wal_size = File.size(wal_path).to_i64
      cached_offsets = active_entry_offsets(wal_path, wal_size)
      close_wal_io(dump_dir)
      reset_entry_index(dump_dir)
      new_segment_path = segment_path(dump_dir, first_lsn)
      if File.exists?(new_segment_path)
        raise Karma::Error.new("validation_error", "WAL segment already exists: #{new_segment_path}")
      end

      File.rename(wal_path, new_segment_path)
      reset_paths_cache(dump_dir)
      begin
        write_segment_index(new_segment_path, cached_offsets)
      rescue ex
        Karma::Log.error("wal.segment_index_failed", ex.message || ex.class.name)
      end
      Karma::Log.info("wal.segment", "path=#{new_segment_path}")
    end
  end
end
