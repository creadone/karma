module Karma
  class Runtime
    getter cluster : Cluster
    getter server : Server
    getter replication_poller : Replication::Poller?

    def self.build : Runtime
      Karma.config.validate!
      Karma::Recovery.load!(Karma.config.dump_dir)

      cluster = if Karma.config.restore
                  Cluster.restore_with_wal(Karma.config.dump_dir)
                else
                  Cluster.new
                end

      new(cluster, Server.new(cluster), Replication::Poller.build?(cluster))
    end

    def initialize(@cluster : Cluster, @server : Server, @replication_poller : Replication::Poller? = nil)
    end

    def start_replication! : Nil
      @replication_poller.try(&.start!)
    end

    def stop! : Nil
      @replication_poller.try(&.stop!)
      @server.stop!
    end
  end
end
