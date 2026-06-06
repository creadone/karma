require "./spec_helper"

describe Karma::Wal do
  it "writes mutating commands to WAL" do
    dump_dir = File.expand_path(".spec_wal_append_#{Time.local.to_unix_ms}")
    Karma.configure { |c| c.dump_dir = dump_dir }
    cluster = Karma::Cluster.new

    Karma::Commands.call({
      v:      2,
      op:     "counter.increment",
      series: "articles",
      key:    42_u64,
    }.to_json, cluster)

    lines = File.read_lines(Karma::Wal.path(dump_dir))
    lines.size.should eq(1)
    entry = JSON.parse(lines.first)
    entry["v"].as_i.should eq(2)
    entry["lsn"].as_i.should eq(1)
    entry["entry"]["v"].as_i.should eq(2)
    entry["entry"]["op"].as_s.should eq("counter.increment")
    entry["entry"].as_h.has_key?("bucket").should be_true
    entry["entry"]["value"].as_i.should eq(1)
    Karma::Wal.current_lsn(dump_dir).should eq(1_u64)
  end

  it "increments and persists WAL LSNs" do
    dump_dir = File.expand_path(".spec_wal_lsn_#{Time.local.to_unix_ms}")
    Karma.configure { |c| c.dump_dir = dump_dir }
    cluster = Karma::Cluster.new

    Karma::Commands.call({v: 2, op: "counter.increment", tree: "articles", key: 42_u64}.to_json, cluster)
    Karma::Commands.call({v: 2, op: "counter.increment", tree: "articles", key: 43_u64}.to_json, cluster)

    lines = File.read_lines(Karma::Wal.path(dump_dir)).map { |line| JSON.parse(line) }
    lines.map { |line| line["lsn"].as_i }.should eq([1, 2])
    Karma::Wal.current_lsn(dump_dir).should eq(2_u64)
  end

  it "keeps LSNs monotonic when concurrent appends are batched" do
    dump_dir = File.expand_path(".spec_wal_batched_appends_#{Time.local.to_unix_ms}")
    Karma.configure do |c|
      c.dump_dir = dump_dir
      c.wal_batch_size = 64
      c.wal_batch_wait_microseconds = 1_000
    end
    cluster = Karma::Cluster.new
    done = Channel(Nil).new
    writes = 64

    writes.times do |index|
      spawn do
        Karma::Commands.call({v: 2, op: "counter.increment", series: "series-#{index}", key: index.to_u64}.to_json, cluster)
        done.send(nil)
      end
    end

    writes.times { done.receive }

    lines = File.read_lines(Karma::Wal.path(dump_dir)).map { |line| JSON.parse(line) }
    lines.map { |line| line["lsn"].as_i }.should eq((1..writes).to_a)
    Karma::Wal.current_lsn(dump_dir).should eq(writes.to_u64)

    restored = Karma::Cluster.restore_with_wal(dump_dir)
    writes.times do |index|
      restored.get("series-#{index}").sum(index.to_u64).should eq(1_u64)
    end
  ensure
    Karma.configure do |c|
      c.wal_batch_size = 1_024
      c.wal_batch_wait_microseconds = 0
    end
  end

  it "reads WAL entries after LSN with limit" do
    dump_dir = File.expand_path(".spec_wal_entries_after_#{Time.local.to_unix_ms}")
    Karma.configure { |c| c.dump_dir = dump_dir }
    cluster = Karma::Cluster.new

    Karma::Commands.call({v: 2, op: "counter.increment", tree: "articles", key: 41_u64}.to_json, cluster)
    Karma::Commands.call({v: 2, op: "counter.increment", tree: "articles", key: 42_u64}.to_json, cluster)
    Karma::Commands.call({v: 2, op: "counter.increment", tree: "articles", key: 43_u64}.to_json, cluster)

    entries = Karma::Wal.entries_after(1_u64, 1, dump_dir)

    entries.size.should eq(1)
    entries.first.lsn.should eq(2_u64)
    entries.first.entry["op"].as_s.should eq("counter.increment")
    entries.first.entry["key"].as_i.should eq(42)
  end

  it "reads WAL entries appended after building the entry offset index" do
    dump_dir = File.expand_path(".spec_wal_entries_index_append_#{Time.local.to_unix_ms}")
    Karma.configure { |c| c.dump_dir = dump_dir }
    cluster = Karma::Cluster.new

    Karma::Commands.call({v: 2, op: "counter.increment", tree: "articles", key: 41_u64}.to_json, cluster)
    Karma::Commands.call({v: 2, op: "counter.increment", tree: "articles", key: 42_u64}.to_json, cluster)
    Karma::Wal.entries_after(0_u64, 10, dump_dir).map { |entry| entry.lsn }.should eq([1_u64, 2_u64])

    Karma::Commands.call({v: 2, op: "counter.increment", tree: "articles", key: 43_u64}.to_json, cluster)

    entries = Karma::Wal.entries_after(2_u64, 10, dump_dir)
    entries.map { |entry| entry.lsn }.should eq([3_u64])
    entries.first.entry["key"].as_i.should eq(43)
  end

  it "rebuilds the WAL entry offset index after external WAL rewrite" do
    dump_dir = File.expand_path(".spec_wal_entries_index_rewrite_#{Time.local.to_unix_ms}")
    Karma.configure { |c| c.dump_dir = dump_dir }
    cluster = Karma::Cluster.new

    Karma::Commands.call({v: 2, op: "counter.increment", tree: "articles", key: 41_u64}.to_json, cluster)
    Karma::Commands.call({v: 2, op: "counter.increment", tree: "articles", key: 42_u64}.to_json, cluster)
    Karma::Commands.call({v: 2, op: "counter.increment", tree: "articles", key: 43_u64}.to_json, cluster)
    Karma::Wal.entries_after(0_u64, 10, dump_dir).map { |entry| entry.lsn }.should eq([1_u64, 2_u64, 3_u64])

    lines = File.read_lines(Karma::Wal.path(dump_dir))
    File.write(Karma::Wal.path(dump_dir), "#{lines[2]}\n")

    entries = Karma::Wal.entries_after(0_u64, 10, dump_dir)
    entries.map { |entry| entry.lsn }.should eq([3_u64])
    entries.first.entry["key"].as_i.should eq(43)
  end

  it "finds beginning, middle, and tail entries in the active WAL after resetting in-memory indexes" do
    dump_dir = File.expand_path(".spec_wal_active_binary_tail_#{Time.local.to_unix_ms}")
    Karma.configure do |c|
      c.dump_dir = dump_dir
      c.wal_segment_bytes = 0
    end
    cluster = Karma::Cluster.new

    100.times do |index|
      Karma::Commands.call({v: 2, op: "counter.increment", tree: "articles", key: index.to_u64}.to_json, cluster)
    end

    Karma::Wal.reset!

    beginning = Karma::Wal.entries_after(0_u64, 3, dump_dir)
    beginning.map { |entry| entry.lsn }.should eq([1_u64, 2_u64, 3_u64])
    beginning.map { |entry| entry.entry["key"].as_i }.should eq([0, 1, 2])

    middle = Karma::Wal.entries_after(49_u64, 4, dump_dir)
    middle.map { |entry| entry.lsn }.should eq([50_u64, 51_u64, 52_u64, 53_u64])
    middle.map { |entry| entry.entry["key"].as_i }.should eq([49, 50, 51, 52])

    tail = Karma::Wal.entries_after(90_u64, 5, dump_dir)
    tail.map { |entry| entry.lsn }.should eq([91_u64, 92_u64, 93_u64, 94_u64, 95_u64])
    tail.map { |entry| entry.entry["key"].as_i }.should eq([90, 91, 92, 93, 94])

    Karma::Wal.entries_after(100_u64, 5, dump_dir).should be_empty
  end

  it "indexes WAL entries when envelope fields are not in serializer order" do
    dump_dir = File.expand_path(".spec_wal_entries_index_fallback_#{Time.local.to_unix_ms}")
    Karma.configure { |c| c.dump_dir = dump_dir }
    Dir.mkdir_p(dump_dir)
    File.write(Karma::Wal.path(dump_dir), {
      entry: {
        v:     2,
        op:    "counter.increment",
        tree:  "articles",
        key:   42_u64,
        date:  20260505_u64,
        value: 1_u64,
      },
      lsn: 1_u64,
      v:   2,
    }.to_json + "\n")

    entries = Karma::Wal.entries_after(0_u64, 10, dump_dir)

    entries.map { |entry| entry.lsn }.should eq([1_u64])
    entries.first.entry["key"].as_i.should eq(42)
  end

  it "reads WAL entries after LSN with byte budget" do
    dump_dir = File.expand_path(".spec_wal_entries_budget_#{Time.local.to_unix_ms}")
    Karma.configure { |c| c.dump_dir = dump_dir }
    cluster = Karma::Cluster.new

    Karma::Commands.call({v: 2, op: "counter.increment", tree: "articles", key: 41_u64}.to_json, cluster)
    Karma::Commands.call({v: 2, op: "counter.increment", tree: "articles", key: 42_u64}.to_json, cluster)
    Karma::Commands.call({v: 2, op: "counter.increment", tree: "articles", key: 43_u64}.to_json, cluster)

    first_entry = Karma::Wal.entries_after(0_u64, 1, dump_dir).first
    page = Karma::Wal.entries_page_after(0_u64, 10, dump_dir, max_bytes: first_entry.response_bytes)

    page.entries.size.should eq(1)
    page.entries.first.lsn.should eq(1_u64)
    page.bytes.should eq(first_entry.response_bytes)
    page.truncated_by_bytes.should be_true
  end

  it "rejects a single WAL entry that exceeds the byte budget" do
    dump_dir = File.expand_path(".spec_wal_entries_budget_reject_#{Time.local.to_unix_ms}")
    Karma.configure { |c| c.dump_dir = dump_dir }
    cluster = Karma::Cluster.new

    Karma::Commands.call({v: 2, op: "counter.increment", tree: "articles", key: 41_u64}.to_json, cluster)
    first_entry = Karma::Wal.entries_after(0_u64, 1, dump_dir).first

    expect_raises(Karma::Error, /Single WAL entry/) do
      Karma::Wal.entries_page_after(0_u64, 10, dump_dir, max_bytes: first_entry.response_bytes - 1)
    end
  end

  it "rotates active WAL into segments and reads entries across them" do
    dump_dir = File.expand_path(".spec_wal_segments_#{Time.local.to_unix_ms}")
    Karma.configure do |c|
      c.dump_dir = dump_dir
      c.wal_segment_bytes = 1
    end
    cluster = Karma::Cluster.new

    Karma::Commands.call({v: 2, op: "counter.increment", tree: "articles", key: 41_u64}.to_json, cluster)
    Karma::Commands.call({v: 2, op: "counter.increment", tree: "articles", key: 42_u64}.to_json, cluster)
    Karma::Commands.call({v: 2, op: "counter.increment", tree: "articles", key: 43_u64}.to_json, cluster)

    segments = Karma::Wal.segment_paths(dump_dir)
    segments.size.should eq(2)
    segments.each do |segment_path|
      index_path = Karma::Wal.segment_index_path(segment_path)
      File.exists?(index_path).should be_true
      index_lines = File.read_lines(index_path)
      segment_lines = File.read_lines(segment_path)
      segment_size = File.size(segment_path)

      index_lines.first.should eq("KARMA_WAL_INDEX_V1 size=#{segment_size}")
      index_lines[1..].size.should eq(segment_lines.size)
      index_lines[1..].each_with_index do |index_line, line_index|
        parts = index_line.split(' ', remove_empty: true)
        parts.size.should eq(2)
        lsn = parts[0].to_u64
        offset = parts[1].to_i64

        lsn.should eq(JSON.parse(segment_lines[line_index])["lsn"].as_i64.to_u64)
        offset.should be >= 0
        offset.should be < segment_size
      end
    end
    File.read_lines(Karma::Wal.path(dump_dir)).size.should eq(1)

    Karma::Wal.reset!
    entries = Karma::Wal.entries_after(0_u64, 10, dump_dir)
    entries.map { |entry| entry.lsn }.should eq([1_u64, 2_u64, 3_u64])
    Karma::Wal.entries_after(1_u64, 10, dump_dir).map { |entry| entry.lsn }.should eq([2_u64, 3_u64])
    Karma::Wal.current_lsn(dump_dir).should eq(3_u64)

    restored = Karma::Cluster.restore_with_wal(dump_dir)
    restored.get("articles").sum(41_u64).should eq(1_u64)
    restored.get("articles").sum(42_u64).should eq(1_u64)
    restored.get("articles").sum(43_u64).should eq(1_u64)

    report = Karma::Backup.verify(dump_dir)
    report[:wal_entries_checked].should eq(3)
    report[:wal_first_lsn].should eq(1_u64)
    report[:wal_last_lsn].should eq(3_u64)
  end

  it "falls back to scanning a segment when its sidecar index is stale" do
    dump_dir = File.expand_path(".spec_wal_segment_stale_index_#{Time.local.to_unix_ms}")
    Karma.configure do |c|
      c.dump_dir = dump_dir
      c.wal_segment_bytes = 1
    end
    cluster = Karma::Cluster.new

    Karma::Commands.call({v: 2, op: "counter.increment", tree: "articles", key: 41_u64}.to_json, cluster)
    Karma::Commands.call({v: 2, op: "counter.increment", tree: "articles", key: 42_u64}.to_json, cluster)
    segment_path = Karma::Wal.segment_paths(dump_dir).first
    File.write(Karma::Wal.segment_index_path(segment_path), "KARMA_WAL_INDEX_V1 size=0\n999 0\n")

    Karma::Wal.reset!
    entries = Karma::Wal.entries_after(0_u64, 10, dump_dir)

    entries.map { |entry| entry.lsn }.should eq([1_u64, 2_u64])
    entries.map { |entry| entry.entry["key"].as_i }.should eq([41, 42])
  end

  it "falls back to scanning a segment when its sidecar index starts inside a WAL line" do
    dump_dir = File.expand_path(".spec_wal_segment_bad_index_offset_#{Time.local.to_unix_ms}")
    Karma.configure do |c|
      c.dump_dir = dump_dir
      c.wal_segment_bytes = 1
    end
    cluster = Karma::Cluster.new

    Karma::Commands.call({v: 2, op: "counter.increment", tree: "articles", key: 41_u64}.to_json, cluster)
    Karma::Commands.call({v: 2, op: "counter.increment", tree: "articles", key: 42_u64}.to_json, cluster)
    segment_path = Karma::Wal.segment_paths(dump_dir).first
    File.write(Karma::Wal.segment_index_path(segment_path), "KARMA_WAL_INDEX_V1 size=#{File.size(segment_path)}\n1 1\n")

    Karma::Wal.reset!
    entries = Karma::Wal.entries_after(0_u64, 10, dump_dir)

    entries.map { |entry| entry.lsn }.should eq([1_u64, 2_u64])
    entries.map { |entry| entry.entry["key"].as_i }.should eq([41, 42])
  end

  it "falls back to scanning a segment when a later sidecar index offset points inside a WAL line" do
    dump_dir = File.expand_path(".spec_wal_segment_bad_later_index_offset_#{Time.local.to_unix_ms}")
    Karma.configure do |c|
      c.dump_dir = dump_dir
      c.wal_segment_bytes = 10_000
    end
    cluster = Karma::Cluster.new

    Karma::Commands.call({v: 2, op: "counter.increment", tree: "articles", key: 41_u64}.to_json, cluster)
    Karma::Commands.call({v: 2, op: "counter.increment", tree: "articles", key: 42_u64}.to_json, cluster)
    Karma.config.wal_segment_bytes = 1
    Karma::Commands.call({v: 2, op: "counter.increment", tree: "articles", key: 43_u64}.to_json, cluster)
    segment_path = Karma::Wal.segment_paths(dump_dir).first
    segment_lines = File.read_lines(segment_path)
    bad_second_offset = segment_lines.first.bytesize + 2
    File.write(
      Karma::Wal.segment_index_path(segment_path),
      "KARMA_WAL_INDEX_V1 size=#{File.size(segment_path)}\n1 0\n2 #{bad_second_offset}\n"
    )

    Karma::Wal.reset!
    entries = Karma::Wal.entries_after(1_u64, 10, dump_dir)

    entries.map { |entry| entry.lsn }.should eq([2_u64, 3_u64])
    entries.map { |entry| entry.entry["key"].as_i }.should eq([42, 43])
  end

  it "invalidates cached WAL paths after segment rotation" do
    dump_dir = File.expand_path(".spec_wal_segment_paths_cache_#{Time.local.to_unix_ms}")
    Karma.configure do |c|
      c.dump_dir = dump_dir
      c.wal_segment_bytes = 1
    end
    cluster = Karma::Cluster.new

    Karma::Commands.call({v: 2, op: "counter.increment", tree: "articles", key: 41_u64}.to_json, cluster)
    Karma::Wal.paths(dump_dir).should eq([Karma::Wal.path(dump_dir)])

    Karma::Commands.call({v: 2, op: "counter.increment", tree: "articles", key: 42_u64}.to_json, cluster)

    paths = Karma::Wal.paths(dump_dir)
    paths.size.should eq(2)
    paths.first.ends_with?(Karma::Wal::SEGMENT_EXTENSION).should be_true
    paths.last.should eq(Karma::Wal.path(dump_dir))
  end

  it "reads entries after cycling through more WAL files than the offset cache holds" do
    dump_dir = File.expand_path(".spec_wal_entry_offset_cache_eviction_#{Time.local.to_unix_ms}")
    Karma.configure do |c|
      c.dump_dir = dump_dir
      c.wal_segment_bytes = 1
    end
    cluster = Karma::Cluster.new
    entries_count = Karma::Wal::ENTRY_OFFSET_CACHE_FILES + 5

    entries_count.times do |index|
      Karma::Commands.call({v: 2, op: "counter.increment", tree: "articles", key: index.to_u64}.to_json, cluster)
    end

    Karma::Wal.reset!
    entries_count.times do |index|
      entries = Karma::Wal.entries_after(index.to_u64, 1, dump_dir)
      entries.map { |entry| entry.lsn }.should eq([(index + 1).to_u64])
    end
    Karma::Wal.entries_after(entries_count.to_u64, 1, dump_dir).should be_empty
  end

  it "removes WAL segments when truncating after snapshots" do
    dump_dir = File.expand_path(".spec_wal_segments_truncate_#{Time.local.to_unix_ms}")
    Karma.configure do |c|
      c.dump_dir = dump_dir
      c.wal_segment_bytes = 1
    end
    cluster = Karma::Cluster.new

    Karma::Commands.call({v: 2, op: "counter.increment", tree: "articles", key: 41_u64}.to_json, cluster)
    Karma::Commands.call({v: 2, op: "counter.increment", tree: "articles", key: 42_u64}.to_json, cluster)
    segments = Karma::Wal.segment_paths(dump_dir)
    segments.should_not be_empty
    index_paths = segments.map { |segment_path| Karma::Wal.segment_index_path(segment_path) }
    index_paths.each { |index_path| File.exists?(index_path).should be_true }

    cluster.dump_all

    Karma::Wal.segment_paths(dump_dir).should be_empty
    index_paths.each { |index_path| File.exists?(index_path).should be_false }
    File.read(Karma::Wal.path(dump_dir)).should be_empty
    Karma::Wal.current_lsn(dump_dir).should eq(2_u64)

    restored = Karma::Cluster.restore_with_wal(dump_dir)
    restored.get("articles").sum(41_u64).should eq(1_u64)
    restored.get("articles").sum(42_u64).should eq(1_u64)
  end

  it "skips unwrapped WAL entries when reading entries after LSN" do
    dump_dir = File.expand_path(".spec_wal_entries_unwrapped_#{Time.local.to_unix_ms}")
    Karma.configure { |c| c.dump_dir = dump_dir }
    Dir.mkdir_p(dump_dir)
    File.write(Karma::Wal.path(dump_dir), {
      v:    2,
      op:   "counter.increment",
      tree: "articles",
      key:  42_u64,
    }.to_json + "\n")

    Karma::Wal.entries_after(0_u64, 100, dump_dir).should be_empty
  end

  it "replays WAL after snapshot restore" do
    dump_dir = File.expand_path(".spec_wal_replay_#{Time.local.to_unix_ms}")
    Karma.configure { |c| c.dump_dir = dump_dir }
    cluster = Karma::Cluster.new

    Karma::Commands.call({
      v:      2,
      op:     "counter.increment",
      series: "articles",
      key:    42_u64,
    }.to_json, cluster)

    restored = Karma::Cluster.restore_with_wal(dump_dir)

    restored.trees.keys.should contain("articles")
    restored.get("articles").sum(42_u64).should eq(1_u64)
  end

  it "replays WAL on slave role" do
    dump_dir = File.expand_path(".spec_wal_slave_replay_#{Time.local.to_unix_ms}")
    Karma.configure { |c| c.dump_dir = dump_dir }
    cluster = Karma::Cluster.new

    Karma::Commands.call({v: 2, op: "counter.increment", tree: "articles", key: 42_u64}.to_json, cluster)
    Karma.configure { |c| c.role = "slave" }

    restored = Karma::Cluster.restore_with_wal(dump_dir)

    restored.get("articles").sum(42_u64).should eq(1_u64)
  ensure
    Karma.configure { |c| c.role = "master" }
  end

  it "truncates WAL after dumping all trees" do
    dump_dir = File.expand_path(".spec_wal_compact_#{Time.local.to_unix_ms}")
    Karma.configure { |c| c.dump_dir = dump_dir }
    cluster = Karma::Cluster.new

    Karma::Commands.call({
      v:      2,
      op:     "counter.increment",
      series: "articles",
      key:    42_u64,
    }.to_json, cluster)
    File.read(Karma::Wal.path(dump_dir)).should_not be_empty

    cluster.dump_all

    File.read(Karma::Wal.path(dump_dir)).should be_empty
    File.read(Karma::Wal.lsn_path(dump_dir)).strip.should eq("1")
    restored = Karma::Cluster.restore_with_wal(dump_dir)
    restored.get("articles").sum(42_u64).should eq(1_u64)
  end

  it "appends cleanly after truncating an open WAL" do
    dump_dir = File.expand_path(".spec_wal_append_after_truncate_#{Time.local.to_unix_ms}")
    Karma.configure { |c| c.dump_dir = dump_dir }
    cluster = Karma::Cluster.new

    Karma::Commands.call({v: 2, op: "counter.increment", tree: "articles", key: 41_u64}.to_json, cluster)
    cluster.dump_all
    Karma::Commands.call({v: 2, op: "counter.increment", tree: "articles", key: 42_u64}.to_json, cluster)

    lines = File.read_lines(Karma::Wal.path(dump_dir))
    lines.size.should eq(1)
    entry = JSON.parse(lines.first)
    entry["lsn"].as_i.should eq(2)
    entry["entry"]["key"].as_i.should eq(42)
    Karma::Wal.current_lsn(dump_dir).should eq(2_u64)

    restored = Karma::Cluster.restore_with_wal(dump_dir)
    restored.get("articles").sum(41_u64).should eq(1_u64)
    restored.get("articles").sum(42_u64).should eq(1_u64)
  end

  it "rejects unwrapped v2 WAL entries during restore" do
    dump_dir = File.expand_path(".spec_wal_unwrapped_v2_#{Time.local.to_unix_ms}")
    Karma.configure { |c| c.dump_dir = dump_dir }
    Dir.mkdir_p(dump_dir)
    File.write(Karma::Wal.path(dump_dir), {
      v:     2,
      op:    "counter.increment",
      tree:  "articles",
      key:   42_u64,
      value: 3_u64,
    }.to_json + "\n")

    expect_raises(Karma::Error, /WAL entry without v2 LSN envelope/) do
      Karma::Cluster.restore_with_wal(dump_dir)
    end
  end

  it "can disable WAL persistence" do
    dump_dir = File.expand_path(".spec_wal_disabled_#{Time.local.to_unix_ms}")
    Karma.configure do |c|
      c.dump_dir = dump_dir
      c.wal = false
    end
    cluster = Karma::Cluster.new

    Karma::Commands.call({
      v:      2,
      op:     "counter.increment",
      series: "articles",
      key:    42_u64,
    }.to_json, cluster)

    File.exists?(Karma::Wal.path(dump_dir)).should be_false
  ensure
    Karma.configure { |c| c.wal = true }
  end

  it "can write WAL without fsync" do
    dump_dir = File.expand_path(".spec_wal_no_fsync_#{Time.local.to_unix_ms}")
    Karma.configure do |c|
      c.dump_dir = dump_dir
      c.wal_fsync = false
    end
    cluster = Karma::Cluster.new

    Karma::Commands.call({
      v:      2,
      op:     "counter.increment",
      series: "articles",
      key:    42_u64,
    }.to_json, cluster)

    File.read(Karma::Wal.path(dump_dir)).should contain("\"op\":\"counter.increment\"")
  ensure
    Karma.configure { |c| c.wal_fsync = true }
  end

  it "does not persist auth token in WAL" do
    dump_dir = File.expand_path(".spec_wal_auth_#{Time.local.to_unix_ms}")
    Karma.configure do |c|
      c.dump_dir = dump_dir
      c.auth_token = "secret"
    end
    cluster = Karma::Cluster.new

    Karma::Commands.call({
      v:      2,
      op:     "counter.increment",
      series: "articles",
      key:    42_u64,
      token:  "secret",
    }.to_json, cluster)

    wal = File.read(Karma::Wal.path(dump_dir))
    wal.should contain("\"op\":\"counter.increment\"")
    wal.should_not contain("secret")
    Karma::Cluster.restore_with_wal(dump_dir).get("articles").sum(42_u64).should eq(1_u64)
  ensure
    Karma.configure { |c| c.auth_token = nil }
  end

  it "rejects v1 WAL entries during restore" do
    dump_dir = File.expand_path(".spec_wal_v1_rejected_#{Time.local.to_unix_ms}")
    Karma.configure { |c| c.dump_dir = dump_dir }
    Dir.mkdir_p(dump_dir)
    File.write(Karma::Wal.path(dump_dir), {
      command:   "increment",
      tree_name: "articles",
      key:       42_u64,
    }.to_json + "\n")

    expect_raises(Karma::Error, /WAL entry without v2 LSN envelope/) do
      Karma::Cluster.restore_with_wal(dump_dir)
    end
  end

  it "writes batch increments to one WAL entry and replays them" do
    dump_dir = File.expand_path(".spec_wal_batch_add_#{Time.local.to_unix_ms}")
    Karma.configure { |c| c.dump_dir = dump_dir }
    cluster = Karma::Cluster.new

    Karma::Commands.call({
      v:      2,
      op:     "series.batch_add",
      series: "articles",
      items:  [
        [42_u64, 20260505_u64, 10_u64],
        [43_u64, 20260505_u64, 7_u64],
      ],
    }.to_json, cluster)

    lines = File.read_lines(Karma::Wal.path(dump_dir))
    lines.size.should eq(1)
    lines.first.should contain("\"op\":\"series.batch_add\"")
    lines.first.should contain("\"items\"")

    restored = Karma::Cluster.restore_with_wal(dump_dir)
    restored.get("articles").sum(42_u64).should eq(10_u64)
    restored.get("articles").sum(43_u64).should eq(7_u64)
  end

  it "writes new batch counter mutations to WAL and replays them" do
    dump_dir = File.expand_path(".spec_wal_batch_mutations_#{Time.local.to_unix_ms}")
    Karma.configure { |c| c.dump_dir = dump_dir }
    cluster = Karma::Cluster.new

    Karma::Commands.call({
      v:      2,
      op:     "series.batch_set",
      series: "articles",
      items:  [
        [42_u64, 20260501_u64, 10_u64],
        [42_u64, 20260502_u64, 7_u64],
        [43_u64, 20260501_u64, 3_u64],
      ],
    }.to_json, cluster)
    Karma::Commands.call({
      v:      2,
      op:     "counter.batch_delete_range",
      series: "articles",
      keys:   [42_u64],
      range:  {from: 20260501_u64, to: 20260501_u64},
    }.to_json, cluster)
    Karma::Commands.call({
      v:      2,
      op:     "counter.batch_reset",
      series: "articles",
      keys:   [43_u64],
    }.to_json, cluster)

    wal = File.read(Karma::Wal.path(dump_dir))
    wal.should contain("\"op\":\"series.batch_set\"")
    wal.should contain("\"op\":\"counter.batch_delete_range\"")
    wal.should contain("\"op\":\"counter.batch_reset\"")

    restored = Karma::Cluster.restore_with_wal(dump_dir)
    restored.get("articles").sum(42_u64, 20260501_u64, 20260501_u64).should eq(0_u64)
    restored.get("articles").sum(42_u64, 20260502_u64, 20260502_u64).should eq(7_u64)
    restored.get("articles").sum(43_u64).should eq(0_u64)
  end

  it "replays streaming ingest chunks idempotently" do
    dump_dir = File.expand_path(".spec_wal_ingest_#{Time.local.to_unix_ms}")
    Karma.configure { |c| c.dump_dir = dump_dir }
    cluster = Karma::Cluster.new

    Karma::Commands.call({v: 2, op: "ingest.begin", mode: "add", stream_id: "wal-stream"}.to_json, cluster)
    chunk = {
      v:         2,
      op:        "ingest.chunk",
      stream_id: "wal-stream",
      series:    "articles",
      chunk_seq: 1_u64,
      items:     [[42_u64, 20260505_u64, 10_u64]],
    }.to_json
    Karma::Commands.call(chunk, cluster)
    Karma::Commands.call(chunk, cluster)
    Karma::Commands.call({v: 2, op: "ingest.commit", stream_id: "wal-stream"}.to_json, cluster)

    lines = File.read_lines(Karma::Wal.path(dump_dir))
    lines.size.should eq(4)
    lines[0].should contain("\"op\":\"ingest.begin\"")
    lines[1].should contain("\"op\":\"ingest.chunk\"")
    lines[2].should contain("\"op\":\"ingest.chunk\"")
    lines[3].should contain("\"op\":\"ingest.commit\"")

    Karma::Ingest.reset!
    restored = Karma::Cluster.restore_with_wal(dump_dir)
    restored.get("articles").sum(42_u64).should eq(10_u64)
  end

  it "replays replace_series ingest with atomic commit" do
    dump_dir = File.expand_path(".spec_wal_ingest_replace_#{Time.local.to_unix_ms}")
    Karma.configure { |c| c.dump_dir = dump_dir }
    cluster = Karma::Cluster.new

    Karma::Commands.call({v: 2, op: "counter.increment", series: "articles", key: 1_u64, bucket: 20260505_u64, value: 99_u64}.to_json, cluster)
    Karma::Commands.call({v: 2, op: "ingest.begin", mode: "replace_series", stream_id: "replace-stream"}.to_json, cluster)
    Karma::Commands.call({
      v:         2,
      op:        "ingest.chunk",
      stream_id: "replace-stream",
      series:    "articles",
      chunk_seq: 1_u64,
      items:     [[2_u64, 20260505_u64, 5_u64]],
    }.to_json, cluster)
    Karma::Commands.call({v: 2, op: "ingest.commit", stream_id: "replace-stream"}.to_json, cluster)

    Karma::Ingest.reset!
    restored = Karma::Cluster.restore_with_wal(dump_dir)
    restored.get("articles").sum(1_u64).should eq(0_u64)
    restored.get("articles").sum(2_u64).should eq(5_u64)
  end

  it "replays retention and compact commands" do
    dump_dir = File.expand_path(".spec_wal_retention_#{Time.local.to_unix_ms}")
    Karma.configure { |c| c.dump_dir = dump_dir }
    cluster = Karma::Cluster.new

    Karma::Commands.call({v: 2, op: "counter.increment", tree: "articles", key: 42_u64, date: 20260501_u64, value: 2_u64}.to_json, cluster)
    Karma::Commands.call({v: 2, op: "counter.increment", tree: "articles", key: 42_u64, date: 20260503_u64, value: 3_u64}.to_json, cluster)
    Karma::Commands.call({v: 2, op: "series.delete_before", series: "articles", before: 20260503_u64}.to_json, cluster)
    Karma::Commands.call({v: 2, op: "counter.decrement", tree: "articles", key: 42_u64, date: 20260503_u64, value: 3_u64}.to_json, cluster)
    Karma::Commands.call({v: 2, op: "system.compact"}.to_json, cluster)

    wal = File.read(Karma::Wal.path(dump_dir))
    wal.should contain("\"op\":\"series.delete_before\"")
    wal.should contain("\"op\":\"system.compact\"")

    restored = Karma::Cluster.restore_with_wal(dump_dir)
    restored.get("articles").sum(42_u64).should eq(0_u64)
    restored.key_count.should eq(0)
  end
end
