module Karma
  module Backup
    def self.verify(dump_dir)
      snapshot_report = verify_snapshot_metadata(dump_dir)
      wal_report = verify_wal_continuity(dump_dir, snapshot_report[:restore_lsn])
      cluster = Cluster.restore_with_wal(dump_dir)
      cluster.validate!
      {
        status:                    "ok",
        dump_count:                snapshot_report[:dump_count],
        trees:                     cluster.tree_count,
        keys:                      cluster.key_count,
        snapshot_metadata_checked: snapshot_report[:checked],
        legacy_snapshot_count:     snapshot_report[:legacy],
        restore_snapshot_lsn:      snapshot_report[:restore_lsn],
        wal_entries_checked:       wal_report[:entries],
        wal_legacy_entries:        wal_report[:legacy_entries],
        wal_first_lsn:             wal_report[:first_lsn],
        wal_last_lsn:              wal_report[:last_lsn],
        wal_lsn_file:              wal_report[:lsn_file],
      }
    end

    def self.info(dump_dir)
      dump_paths = dumps(dump_dir)
      latest_by_tree = latest_snapshot_metadata_by_tree(dump_dir).map(&.to_response)

      {
        dump_count:              dump_paths.size,
        latest_by_tree:          latest_by_tree,
        idempotency_snapshot:    Karma::Idempotency.info(dump_dir).try(&.to_response),
        last_snapshot_lsn:       latest_by_tree.max_of? { |snapshot| snapshot[:last_lsn] } || 0_u64,
        wal_enabled:             Karma::Wal.enabled?,
        wal_bytes:               Karma::Wal.bytes(dump_dir),
        wal_current_lsn:         Karma::Wal.current_lsn(dump_dir),
        dump_retention_per_tree: Karma.config.dump_retention_per_tree,
      }
    end

    private def self.verify_snapshot_metadata(dump_dir)
      checked = 0
      legacy = 0
      dump_paths = dumps(dump_dir)

      dump_paths.each do |path|
        metadata_path = metadata_path(path)
        unless File.exists?(metadata_path)
          legacy += 1
          next
        end

        metadata = SnapshotMetadata.from_json(File.read(metadata_path))
        expected_file = File.basename(path)
        expected_tree = dump_tree_name(path)
        expected_timestamp = dump_timestamp(path)
        expected_bytes = File.size(path)

        raise Karma::Error.new("validation_error", "Snapshot metadata file mismatch for #{expected_file}") unless metadata.file == expected_file
        raise Karma::Error.new("validation_error", "Snapshot metadata tree mismatch for #{expected_file}") unless metadata.tree == expected_tree
        raise Karma::Error.new("validation_error", "Snapshot metadata timestamp mismatch for #{expected_file}") unless metadata.timestamp == expected_timestamp
        raise Karma::Error.new("validation_error", "Snapshot metadata bytes mismatch for #{expected_file}") unless metadata.bytes == expected_bytes

        checked += 1
      rescue e : JSON::ParseException
        raise Karma::Error.new("validation_error", "Invalid snapshot metadata #{metadata_path}: #{e.message}")
      end

      restore_lsn = verify_latest_snapshot_lsn!(dump_dir)
      {
        dump_count:  dump_paths.size,
        checked:     checked,
        legacy:      legacy,
        restore_lsn: restore_lsn,
      }
    end

    private def self.verify_latest_snapshot_lsn!(dump_dir) : UInt64
      snapshots = latest_snapshot_metadata_by_tree(dump_dir)
      return 0_u64 if snapshots.empty?

      lsn_values = snapshots.map(&.last_lsn).uniq
      if lsn_values.size > 1
        raise Karma::Error.new("validation_error", "Latest snapshot metadata has inconsistent last_lsn values")
      end

      lsn_values.first
    end

    private def self.verify_wal_continuity(dump_dir, snapshot_lsn : UInt64)
      wal_paths = Karma::Wal.paths(dump_dir)
      lsn_file = read_wal_lsn_file(dump_dir)
      return empty_wal_report(lsn_file, snapshot_lsn) if wal_paths.empty?

      expected_lsn = snapshot_lsn + 1
      first_lsn : UInt64? = nil
      last_lsn = 0_u64
      entries = 0
      legacy_entries = 0

      wal_paths.each do |wal_path|
        line_number = 0
        File.each_line(wal_path) do |line|
          line_number += 1
          next if line.blank?

          object = JSON.parse(line).as_h
          lsn = object["lsn"]?.try(&.as_i64?.try(&.to_u64))
          entry = object["entry"]?

          if lsn.nil? || entry.nil?
            legacy_entries += 1
            if snapshot_lsn > 0
              raise Karma::Error.new("validation_error", "Legacy WAL entry at #{wal_path}:#{line_number} cannot be verified after snapshot LSN #{snapshot_lsn}")
            end
            next
          end

          if lsn <= snapshot_lsn
            raise Karma::Error.new("validation_error", "WAL entry LSN #{lsn} is already covered by snapshot LSN #{snapshot_lsn}")
          end

          unless lsn == expected_lsn
            raise Karma::Error.new("validation_error", "WAL LSN gap at #{wal_path}:#{line_number}: expected #{expected_lsn}, got #{lsn}")
          end

          first_lsn ||= lsn
          last_lsn = lsn
          entries += 1
          expected_lsn = lsn + 1
        rescue e : JSON::ParseException
          raise Karma::Error.new("validation_error", "Invalid WAL JSON at #{wal_path}:#{line_number}: #{e.message}")
        end
      end

      verify_wal_lsn_file!(lsn_file, snapshot_lsn, last_lsn)
      {
        entries:        entries,
        legacy_entries: legacy_entries,
        first_lsn:      first_lsn || 0_u64,
        last_lsn:       last_lsn,
        lsn_file:       lsn_file || 0_u64,
      }
    end

    private def self.empty_wal_report(lsn_file : UInt64?, snapshot_lsn : UInt64)
      verify_wal_lsn_file!(lsn_file, snapshot_lsn, 0_u64)
      {
        entries:        0,
        legacy_entries: 0,
        first_lsn:      0_u64,
        last_lsn:       0_u64,
        lsn_file:       lsn_file || 0_u64,
      }
    end

    private def self.read_wal_lsn_file(dump_dir) : UInt64?
      file_path = Karma::Wal.lsn_path(dump_dir)
      return nil unless File.exists?(file_path)

      text = File.read(file_path).strip
      return 0_u64 if text.empty?

      text.to_u64
    rescue ArgumentError
      raise Karma::Error.new("validation_error", "Invalid WAL LSN file #{file_path}")
    end

    private def self.verify_wal_lsn_file!(lsn_file : UInt64?, snapshot_lsn : UInt64, wal_last_lsn : UInt64) : Nil
      return if lsn_file.nil?
      return if lsn_file == wal_last_lsn
      return if wal_last_lsn == 0_u64 && lsn_file <= snapshot_lsn

      if lsn_file < wal_last_lsn
        raise Karma::Error.new("validation_error", "WAL LSN file #{lsn_file} is behind WAL last LSN #{wal_last_lsn}")
      end

      raise Karma::Error.new("validation_error", "WAL LSN file #{lsn_file} is ahead of snapshot/WAL LSN #{Math.max(snapshot_lsn, wal_last_lsn)}")
    end
  end
end
