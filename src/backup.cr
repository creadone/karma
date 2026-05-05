module Karma
  module Backup
    DUMP_EXTENSION               = ".tree"
    METADATA_EXTENSION           = ".meta.json"
    SNAPSHOT_CHUNK_DEFAULT_BYTES = 262_144
    SNAPSHOT_CHUNK_MAX_BYTES     = 524_288
  end
end

require "./backup/metadata"
require "./backup/store"
require "./backup/reports"
