module Karma
  module Backup
    DUMP_EXTENSION     = ".tree"
    METADATA_EXTENSION = ".meta.json"
  end
end

require "./backup/metadata"
require "./backup/store"
require "./backup/reports"
