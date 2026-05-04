require "./spec_helper"

class FailingDumpCluster
  getter trees : Hash(String, Bool)

  def initialize
    @trees = {"articles" => true}
  end

  def dump(tree_name)
    raise "boom"
  end
end

describe Karma do
  it "creates dump file with Dump command" do
    dump_dir = File.expand_path(".spec_dumps_#{Time.local.to_unix_ms}")
    Dir.mkdir_p(dump_dir)
    Karma.configure { |c| c.dump_dir = dump_dir }

    cluster = Karma::Cluster.new

    # create tree
    Karma::Commands.call({
      command:   "create",
      tree_name: "articles",
    }.to_json, cluster)

    # make sure there is at least one value
    Karma::Commands.call({
      command:   "increment",
      tree_name: "articles",
      key:       123_u64,
    }.to_json, cluster)

    # dump the tree
    Karma::Commands.call({
      command:   "dump",
      tree_name: "articles",
    }.to_json, cluster)

    files = Dir.glob(File.join(dump_dir, "*.tree"))
    files.size.should be > 0
  end

  it "creates dumps for all trees with DumpAll" do
    dump_dir = File.expand_path(".spec_dumps_all_#{Time.local.to_unix_ms}")
    Dir.mkdir_p(dump_dir)
    Karma.configure { |c| c.dump_dir = dump_dir }

    cluster = Karma::Cluster.new

    %w[one two].each do |name|
      Karma::Commands.call({command: "create", tree_name: name}.to_json, cluster)
      Karma::Commands.call({command: "increment", tree_name: name, key: 1_u64}.to_json, cluster)
    end

    Karma::Commands.call({command: "dump_all"}.to_json, cluster)

    files = Dir.glob(File.join(dump_dir, "*.tree"))
    files.size.should be >= 2
  end

  it "restores trees with underscores in names" do
    dump_dir = File.expand_path(".spec_dumps_restore_names_#{Time.local.to_unix_ms}")
    Dir.mkdir_p(dump_dir)
    Karma.configure { |c| c.dump_dir = dump_dir }

    tree_name = "short_links_daily"
    cluster = Karma::Cluster.new

    Karma::Commands.call({command: "create", tree_name: tree_name}.to_json, cluster)
    Karma::Commands.call({command: "increment", tree_name: tree_name, key: 42_u64}.to_json, cluster)
    Karma::Commands.call({command: "dump", tree_name: tree_name}.to_json, cluster)

    restored = Karma::Cluster.restore(dump_dir)

    restored.trees.keys.should contain(tree_name)
    restored.trees.keys.should_not contain("daily")
    Karma::Commands.call({
      command:   "sum",
      tree_name: tree_name,
      key:       42_u64,
    }.to_json, restored).tap do |response|
      parsed = expect_success(response)
      parsed["response"].as_i.should eq(1)
    end
  end

  it "keeps existing dump file unchanged when dump fails" do
    dump_dir = File.expand_path(".spec_dumps_atomic_#{Time.local.to_unix_ms}")
    Dir.mkdir_p(dump_dir)

    dump_path = File.join(dump_dir, "1_articles.tree")
    File.write(dump_path, "existing")

    expect_raises(Exception, "boom") do
      Karma::Backup.dump(FailingDumpCluster.new, dump_path, "articles")
    end

    File.read(dump_path).should eq("existing")
    Dir.glob(File.join(dump_dir, ".*.tmp")).should be_empty
  end
end
