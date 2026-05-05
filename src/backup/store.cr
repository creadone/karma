require "random/secure"
require "base64"

module Karma
  module Backup
    def self.fetch(file_path : String)
      raise Karma::Error.new("not_found", "Snapshot \"#{File.basename(file_path)}\" not found") unless File.exists?(file_path)

      metadata = snapshot_metadata(file_path)
      {
        metadata:    metadata.to_response,
        data_base64: Base64.strict_encode(File.read(file_path)),
      }
    end

    def self.fetch_chunk(file_path : String, offset : UInt64 = 0_u64, limit : Int32 = SNAPSHOT_CHUNK_DEFAULT_BYTES)
      raise Karma::Error.new("not_found", "Snapshot \"#{File.basename(file_path)}\" not found") unless File.exists?(file_path)
      validate_snapshot_chunk_limit!(limit)

      total_bytes = File.size(file_path).to_u64
      raise Karma::Error.new("validation_error", "Field offset exceeds snapshot size") if offset > total_bytes

      bytes_to_read = Math.min(limit.to_u64, total_bytes - offset).to_i
      data = Bytes.new(bytes_to_read)
      bytes_read = 0

      File.open(file_path, "rb") do |file|
        file.seek(offset.to_i64)
        bytes_read = file.read(data)
      end
      chunk = data[0, bytes_read]
      next_offset = offset + bytes_read.to_u64

      {
        metadata:    snapshot_metadata(file_path).to_response,
        offset:      offset,
        limit:       limit,
        bytes:       bytes_read,
        total_bytes: total_bytes,
        next_offset: next_offset,
        done:        next_offset >= total_bytes,
        data_base64: Base64.strict_encode(chunk),
      }
    end

    def self.install(file_name : String, data : Bytes, metadata : SnapshotMetadata, dump_dir = Karma.config.dump_dir) : String
      install_stream(file_name, metadata, dump_dir) do |io|
        io.write data
      end
    end

    def self.install_stream(file_name : String, metadata : SnapshotMetadata, dump_dir = Karma.config.dump_dir, &) : String
      validate_snapshot_file_name!(file_name)
      raise Karma::Error.new("validation_error", "Snapshot metadata file mismatch") unless metadata.file == file_name
      raise Karma::Error.new("validation_error", "Snapshot metadata tree mismatch") unless metadata.tree == dump_tree_name(file_name)

      dump_dir = File.expand_path(dump_dir)
      Dir.mkdir_p(dump_dir) unless Dir.exists?(dump_dir)
      file_path = File.join(dump_dir, file_name)
      temp_path = File.join(
        dump_dir,
        ".#{file_name}.#{Process.pid}.#{Random::Secure.hex(8)}.tmp"
      )

      File.open(temp_path, "wb") do |io|
        yield io
        io.flush
        io.fsync
      end
      File.rename(temp_path, file_path)
      write_metadata(file_path, metadata.tree, metadata.last_lsn)
      file_path
    ensure
      File.delete(temp_path) if temp_path && File.exists?(temp_path)
    end

    def self.load(cluster, file_path, tree_name)
      if File.exists?(file_path)
        File.open(file_path) do |file|
          io = IO::Memory.new(file.size.to_i)
          IO.copy(file, io)
          cluster.load(tree_name, io.to_slice)
          true
        end
      else
        raise Karma::Error.new("not_found", "Dump \"#{tree_name}\" not found")
      end
    end

    def self.dump(cluster, file_path, tree_name)
      if cluster.trees.has_key?(tree_name)
        dir_path = File.dirname(file_path)
        Dir.mkdir_p(dir_path) unless Dir.exists?(dir_path)

        temp_path = File.join(
          dir_path,
          ".#{File.basename(file_path)}.#{Process.pid}.#{Random::Secure.hex(8)}.tmp"
        )

        File.open(temp_path, "wb") do |io|
          io.write cluster.dump(tree_name)
          io.flush
          io.fsync
        end

        File.rename(temp_path, file_path)
        write_metadata(file_path, tree_name, snapshot_lsn)
        Karma::Log.info("backup.dump", "tree=#{tree_name} path=#{file_path}")
        true
      else
        raise Karma::Error.new("not_found", "Tree \"#{tree_name}\" not found")
      end
    ensure
      File.delete(temp_path) if temp_path && File.exists?(temp_path)
    end

    def self.prune(dump_dir, retain_per_tree : Int32) : Int32
      return 0 if retain_per_tree <= 0

      removed = 0
      dumps(dump_dir)
        .group_by { |path| dump_tree_name(path) }
        .each_value do |paths|
          paths.sort! { |a, b| dump_timestamp(b) <=> dump_timestamp(a) }
          paths.skip(retain_per_tree).each do |path|
            File.delete(path)
            metadata_path = metadata_path(path)
            File.delete(metadata_path) if File.exists?(metadata_path)
            removed += 1
          end
        end
      Karma::Log.info("backup.prune", "removed=#{removed}") if removed > 0
      removed
    end

    private def self.snapshot_lsn : UInt64
      Karma.config.role == "slave" ? Karma::Replication.replayed_lsn : Karma::Wal.current_lsn
    end

    private def self.validate_snapshot_file_name!(file_name : String) : Nil
      raise Karma::Error.new("validation_error", "Snapshot file must be a basename") unless File.basename(file_name) == file_name
      raise Karma::Error.new("validation_error", "Snapshot file must end with .tree") unless file_name.ends_with?(DUMP_EXTENSION)
    end

    private def self.validate_snapshot_chunk_limit!(limit : Int32) : Nil
      raise Karma::Error.new("validation_error", "Field limit must be greater than 0") if limit <= 0
      raise Karma::Error.new("validation_error", "Field limit exceeds max size") if limit > SNAPSHOT_CHUNK_MAX_BYTES
    end

    private def self.write_metadata(file_path : String, tree_name : String, last_lsn : UInt64) : Nil
      metadata_path = metadata_path(file_path)
      temp_path = File.join(
        File.dirname(metadata_path),
        ".#{File.basename(metadata_path)}.#{Process.pid}.#{Random::Secure.hex(8)}.tmp"
      )
      metadata = SnapshotMetadata.new(
        tree_name,
        File.basename(file_path),
        dump_timestamp(file_path),
        last_lsn,
        File.size(file_path)
      )

      File.open(temp_path, "w") do |io|
        metadata.to_json(io)
        io.puts
        io.flush
        io.fsync
      end
      File.rename(temp_path, metadata_path)
    ensure
      File.delete(temp_path) if temp_path && File.exists?(temp_path)
    end
  end
end
