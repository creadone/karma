module Karma
  class QueryDeadline
    CHECK_INTERVAL = 256

    def initialize(timeout_ms : Int32 = Karma.config.query_timeout_ms)
      @deadline = timeout_ms > 0 ? Time.monotonic + timeout_ms.milliseconds : nil
      @timeout_ms = timeout_ms
      @ticks = 0
    end

    def check! : Nil
      deadline = @deadline
      return if deadline.nil?

      @ticks += 1
      return unless @ticks == 1 || (@ticks % CHECK_INTERVAL).zero?
      return if Time.monotonic < deadline

      Karma::Operations.record_query_timeout
      raise Karma::Error.new("query_timeout", "Query exceeded #{@timeout_ms} ms")
    end
  end
end
