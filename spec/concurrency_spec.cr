require "./spec_helper"

describe Karma::State do
  it "coordinates concurrent point writes" do
    dump_dir = File.expand_path(".spec_concurrent_commands_#{Time.local.to_unix_ms}")
    Karma.configure { |c| c.dump_dir = dump_dir }
    cluster = Karma::Cluster.new
    done = Channel(Nil).new

    100.times do
      spawn do
        Karma::Commands.call({
          v:      2,
          op:     "counter.increment",
          series: "articles",
          key:    42_u64,
        }.to_json, cluster)
        done.send(nil)
      end
    end

    100.times { done.receive }

    cluster.get("articles").sum(42_u64).should eq(100_u64)
  end

  it "keeps restore consistent when dump_all runs during writes" do
    dump_dir = File.expand_path(".spec_concurrent_dump_#{Time.local.to_unix_ms}")
    Karma.configure { |c| c.dump_dir = dump_dir }
    cluster = Karma::Cluster.new
    done = Channel(Nil).new

    100.times do
      spawn do
        Karma::Commands.call({
          v:      2,
          op:     "counter.increment",
          series: "articles",
          key:    42_u64,
        }.to_json, cluster)
        done.send(nil)
      end
    end

    spawn do
      Karma::Commands.call({v: 2, op: "snapshot.create_all"}.to_json, cluster)
      done.send(nil)
    end

    101.times { done.receive }

    cluster.get("articles").sum(42_u64).should eq(100_u64)
    restored = Karma::Cluster.restore_with_wal(dump_dir)
    restored.get("articles").sum(42_u64).should eq(100_u64)
  end
end

describe Karma::Wal do
  it "reads WAL pages while writes rotate segments" do
    dump_dir = File.expand_path(".spec_concurrent_wal_reads_#{Time.local.to_unix_ms}")
    Karma.configure do |c|
      c.dump_dir = dump_dir
      c.wal_segment_bytes = 512
    end
    cluster = Karma::Cluster.new
    results = Channel(String?).new
    writes = 200
    readers = 4

    spawn do
      begin
        writes.times do |index|
          Karma::Commands.call({v: 2, op: "counter.increment", tree: "articles", key: index.to_u64}.to_json, cluster)
          sleep 1.milliseconds if index % 25 == 0
        end
        results.send(nil)
      rescue ex
        results.send(ex.message || ex.class.name)
      end
    end

    readers.times do |reader_index|
      spawn do
        begin
          writes.times do |index|
            after_lsn = ((index * (reader_index + 1)) % writes).to_u64
            entries = Karma::Wal.entries_after(after_lsn, 20, dump_dir)
            previous_lsn = after_lsn
            entries.each do |entry|
              raise "non-monotonic WAL page" unless entry.lsn > previous_lsn

              previous_lsn = entry.lsn
            end
            sleep 1.milliseconds if index % 20 == 0
          end
          results.send(nil)
        rescue ex
          results.send(ex.message || ex.class.name)
        end
      end
    end

    (readers + 1).times do
      results.receive.should be_nil
    end

    Karma::Wal.entries_after(0_u64, 10_000, dump_dir).size.should eq(writes)
  end
end
