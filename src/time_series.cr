module Karma
  module TimeSeries
    struct Series
      getter name : String

      def initialize(@name : String)
        raise Karma::Error.new("validation_error", "Series name is required") if @name.empty?
      end
    end

    struct Key
      getter value : UInt64

      def initialize(@value : UInt64)
      end
    end

    struct Bucket
      getter value : UInt64

      def initialize(@value : UInt64)
      end

      def self.today : Bucket
        new(Time.local.to_s("%Y%m%d").to_u64)
      end
    end

    struct BucketRange
      getter from : Bucket
      getter to : Bucket

      def initialize(@from : Bucket, @to : Bucket)
        if @from.value > @to.value
          raise Karma::Error.new("validation_error", "Bucket range start must be less than or equal to range end")
        end
      end
    end
  end
end
