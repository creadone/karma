require "./ingest/stream"

module Karma
  module Ingest
    SUPPORTED_MODES = %w[add set replace_series]

    def self.reset! : Nil
      reset_streams!
      reset_metrics!
    end
  end
end

require "./ingest/registry"
require "./ingest/metrics"
