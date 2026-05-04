require "./spec_helper"

describe Karma::State do
  it "serializes concurrent command execution" do
    dump_dir = File.expand_path(".spec_concurrent_commands_#{Time.local.to_unix_ms}")
    Karma.configure { |c| c.dump_dir = dump_dir }
    cluster = Karma::Cluster.new
    done = Channel(Nil).new

    100.times do
      spawn do
        Karma::Commands.call({
          command:   "increment",
          tree_name: "articles",
          key:       42_u64,
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
          command:   "increment",
          tree_name: "articles",
          key:       42_u64,
        }.to_json, cluster)
        done.send(nil)
      end
    end

    spawn do
      Karma::Commands.call({command: "dump_all"}.to_json, cluster)
      done.send(nil)
    end

    101.times { done.receive }

    cluster.get("articles").sum(42_u64).should eq(100_u64)
    restored = Karma::Cluster.restore_with_wal(dump_dir)
    restored.get("articles").sum(42_u64).should eq(100_u64)
  end
end
