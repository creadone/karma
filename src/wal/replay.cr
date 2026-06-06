require "json"

module Karma
  module Wal
    def self.replay(cluster : Cluster, dump_dir = Karma.config.dump_dir) : Nil
      return unless enabled?
      wal_paths = paths(dump_dir)
      return if wal_paths.empty?

      wal_paths.each do |wal_path|
        File.each_line(wal_path) do |line|
          next if line.blank?

          response = Commands.call(entry_json(line), cluster, persist: false, authorize: false, synchronize: false, track_legacy: false, enforce_request_size: false, enforce_role: false)
          parsed_response = JSON.parse(response)
          unless parsed_response["success"].as_bool
            raise "Cannot replay WAL entry: #{parsed_response["response"]}"
          end
        end
        Karma::Log.info("wal.replay", "path=#{wal_path}")
      end
    end

    private def self.entry_json(line : String) : String
      object = JSON.parse(line).as_h
      entry = object["entry"]?
      entry ? entry.to_json : line
    end
  end
end
