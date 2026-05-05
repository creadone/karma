module Karma
  module Commands
    module Reset

      def self.call(directive, cluster)
        series = directive.series
        cluster.pick(series.name) do |tree|
          unless directive.key.nil?
            key = directive.series_key
            return "OK" if tree.reset(key.value)
          else
            return "OK" if tree.reset
          end
        end
      end

    end
  end
end
