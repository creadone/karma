module Karma
  module Wal
    class AppendJob
      getter directives : Array(Commands::Directive)
      getter dump_dir : String
      getter result : Channel(Exception?)

      def initialize(@directives : Array(Commands::Directive), @dump_dir : String, @result : Channel(Exception?))
      end
    end

    @@append_channel : Channel(AppendJob)?
    @@append_start_mutex = Mutex.new

    def self.append(directive : Commands::Directive) : Bool
      append([directive])
    end

    def self.append(directives : Array(Commands::Directive)) : Bool
      return true unless enabled?
      return true if directives.empty?

      dump_dir = File.expand_path(Karma.config.dump_dir)
      Dir.mkdir_p(dump_dir) unless Dir.exists?(dump_dir)
      result = Channel(Exception?).new(1)
      append_channel.send(AppendJob.new(directives, dump_dir, result))

      if error = result.receive
        raise error
      end

      true
    end

    def self.truncate : Bool
      return true unless enabled?

      dump_dir = File.expand_path(Karma.config.dump_dir)
      Dir.mkdir_p(dump_dir) unless Dir.exists?(dump_dir)

      LSN_MUTEX.synchronize do
        ensure_lsn_loaded(dump_dir)
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
        persist_lsn(dump_dir, @@current_lsn)
      end
      reset_paths_cache(dump_dir)
      Karma::Log.info("wal.truncate", "path=#{path(dump_dir)}")

      true
    end

    private def self.append_channel : Channel(AppendJob)
      channel = @@append_channel
      return channel if channel

      @@append_start_mutex.synchronize do
        channel = @@append_channel
        return channel if channel

        channel = Channel(AppendJob).new
        @@append_channel = channel
        spawn append_writer_loop(channel)
        channel
      end
    end

    private def self.append_writer_loop(channel : Channel(AppendJob)) : Nil
      loop do
        jobs = [channel.receive]
        drain_append_jobs(channel, jobs)
        append_jobs(jobs)
      end
    rescue ex
      Karma::Log.error("wal.writer_stopped", ex.message || ex.class.name)
    end

    private def self.drain_append_jobs(channel : Channel(AppendJob), jobs : Array(AppendJob)) : Nil
      max = Karma.config.wal_batch_size
      max = 1 if max < 1

      Fiber.yield
      drain_available_append_jobs(channel, jobs, max)
      return if jobs.size >= max

      wait_us = Karma.config.wal_batch_wait_microseconds
      return if wait_us <= 0

      deadline = Time.monotonic + wait_us.microseconds
      loop do
        break if jobs.size >= max
        remaining = deadline - Time.monotonic
        break if remaining <= Time::Span.zero

        select
        when job = channel.receive
          jobs << job
        when timeout(remaining)
          break
        end
      end
    end

    private def self.drain_available_append_jobs(channel : Channel(AppendJob), jobs : Array(AppendJob), max : Int32) : Nil
      loop do
        break if jobs.size >= max

        select
        when job = channel.receive
          jobs << job
        when timeout(Time::Span.zero)
          break
        end
      end
    end

    private def self.append_jobs(jobs : Array(AppendJob)) : Nil
      index = 0
      while index < jobs.size
        dump_dir = jobs[index].dump_dir
        group = [] of AppendJob
        while index < jobs.size && jobs[index].dump_dir == dump_dir
          group << jobs[index]
          index += 1
        end
        append_group(dump_dir, group)
      end
    end

    private def self.append_group(dump_dir : String, jobs : Array(AppendJob)) : Nil
      error : Exception? = nil
      begin
        append_group_locked(dump_dir, jobs)
      rescue ex
        error = ex
      end

      jobs.each { |job| job.result.send(error) }
    end

    private def self.append_group_locked(dump_dir : String, jobs : Array(AppendJob)) : Nil
      LSN_MUTEX.synchronize do
        ensure_lsn_loaded(dump_dir)
        rotate_wal_if_needed(dump_dir)

        io = wal_io(dump_dir)
        io.seek(0, IO::Seek::End)

        lsn = @@current_lsn
        offsets = [] of Tuple(UInt64, Int64, Int64)
        jobs.each do |job|
          job.directives.each do |directive|
            lsn += 1
            offset = io.pos.to_i64
            io.puts serialize(directive, lsn)
            offsets << {lsn, offset, io.pos.to_i64}
          end
        end

        io.flush
        io.fsync if fsync?
        offsets.each do |entry_lsn, offset, size|
          record_entry_offset(dump_dir, entry_lsn, offset, size)
        end
        @@current_lsn = lsn
      end
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
