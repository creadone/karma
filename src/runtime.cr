module Karma
  class Runtime
    getter cluster : Cluster
    getter server : Server
    getter replication_poller : Replication::Poller?

    def self.build : Runtime
      Karma.config.validate!
      Karma::Recovery.load!(Karma.config.dump_dir)
      bootstrap_slave_snapshots

      cluster = if Karma.config.restore
                  Cluster.restore_with_wal(Karma.config.dump_dir)
                else
                  Cluster.new
                end
      Karma::Replication.bootstrap_from_snapshots(Karma.config.dump_dir) if Karma.config.role == "slave" && Karma.config.restore

      new(cluster, Server.new(cluster), Replication::Poller.build?(cluster))
    end

    private def self.bootstrap_slave_snapshots : Nil
      return unless Karma.config.role == "slave"
      return unless Karma.config.restore
      return unless Karma::Backup.dumps(Karma.config.dump_dir).empty?

      Karma::Replication::SnapshotClient.build?.try do |client|
        Karma::Replication.record_bootstrap_attempt
        begin
          lsn = client.bootstrap_files(Karma.config.dump_dir)
          Karma::Replication.record_bootstrap_success
          Karma::Log.info("replication.snapshot_bootstrap", "last_lsn=#{lsn}") if lsn > 0
        rescue ex
          Karma::Replication.record_bootstrap_error(ex.message || ex.class.name)
          raise ex
        end
      end
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
