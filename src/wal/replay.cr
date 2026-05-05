require "json"

module Karma
  module Wal
    def self.replay(cluster : Cluster, dump_dir = Karma.config.dump_dir) : Nil
      return unless enabled?
      wal_path = path(dump_dir)
      return unless File.exists?(wal_path)

      File.each_line(wal_path) do |line|
        next if line.blank?

        response = Commands.call(line, cluster, persist: false, authorize: false, synchronize: false, track_legacy: false, enforce_request_size: false)
        parsed_response = JSON.parse(response)
        unless parsed_response["success"].as_bool
          raise "Cannot replay WAL entry: #{parsed_response["response"]}"
        end
      end
      Karma::Log.info("wal.replay", "path=#{wal_path}")
    end
  end
end
