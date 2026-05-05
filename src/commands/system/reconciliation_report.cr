module Karma
  module Commands
    module ReconciliationReport
      def self.call(directive, cluster)
        Karma::Operations.record_reconciliation(
          checked_points: directive.checked_points.not_nil!,
          mismatch_count: directive.mismatch_count.not_nil!,
          absolute_drift: directive.absolute_drift || 0_i64,
          max_abs_delta: directive.max_abs_delta || 0_i64
        )

        "OK"
      end
    end
  end
end
