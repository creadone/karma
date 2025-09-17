require "../src/config"
require "../src/cluster"
require "../src/backup"

dump_dir = "/tmp/.dumps_eval"
Karma.configure { |c| c.dump_dir = dump_dir }
Dir.mkdir_p(dump_dir)

cluster = Karma::Cluster.new
cluster.create("articles")
cluster.pick("articles") { |tree| tree.increment(123_u64) }

cluster.dump_all
sleep 200.milliseconds

files = Dir.glob(File.join(dump_dir, "*.tree"))
puts files.size

