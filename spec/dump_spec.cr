require "./spec_helper"

describe Karma do
  it "creates dump file with Dump command" do
    dump_dir = File.expand_path(".spec_dumps")
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
    dump_dir = File.expand_path(".spec_dumps_all")
    Dir.mkdir_p(dump_dir)
    Karma.configure { |c| c.dump_dir = dump_dir }

    cluster = Karma::Cluster.new

    %w[one two].each do |name|
      Karma::Commands.call({ command: "create", tree_name: name }.to_json, cluster)
      Karma::Commands.call({ command: "increment", tree_name: name, key: 1_u64 }.to_json, cluster)
    end

    Karma::Commands.call({ command: "dump_all" }.to_json, cluster)
    sleep 100.milliseconds

    files = Dir.glob(File.join(dump_dir, "*.tree"))
    files.size.should be >= 2
  end
end


