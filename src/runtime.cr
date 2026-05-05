module Karma
  class Runtime
    getter cluster : Cluster
    getter server : Server

    def self.build : Runtime
      cluster = if Karma.config.restore
                  Cluster.restore_with_wal(Karma.config.dump_dir)
                else
                  Cluster.new
                end

      new(cluster, Server.new(cluster))
    end

    def initialize(@cluster : Cluster, @server : Server)
    end
  end
end
