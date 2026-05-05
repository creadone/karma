require "./spec_helper"

describe Karma::TimeSeries do
  it "wraps v1 tree names as series names" do
    series = Karma::TimeSeries::Series.new("links")

    series.name.should eq("links")
  end

  it "rejects empty series names" do
    expect_raises(Karma::Error, /Series name is required/) do
      Karma::TimeSeries::Series.new("")
    end
  end

  it "wraps counter keys" do
    key = Karma::TimeSeries::Key.new(42_u64)

    key.value.should eq(42_u64)
  end

  it "wraps bucket ranges" do
    range = Karma::TimeSeries::BucketRange.new(
      Karma::TimeSeries::Bucket.new(20230201_u64),
      Karma::TimeSeries::Bucket.new(20230203_u64)
    )

    range.from.value.should eq(20230201_u64)
    range.to.value.should eq(20230203_u64)
  end

  it "rejects inverted bucket ranges" do
    expect_raises(Karma::Error, /Bucket range start/) do
      Karma::TimeSeries::BucketRange.new(
        Karma::TimeSeries::Bucket.new(20230203_u64),
        Karma::TimeSeries::Bucket.new(20230201_u64)
      )
    end
  end

  it "maps v1 directive fields into time-series concepts" do
    directive = Karma::Commands::Directive.from_json({
      command:   "sum",
      tree_name: "links",
      key:       42_u64,
      time_from: 20230201_u64,
      time_to:   20230203_u64,
    }.to_json)

    directive.series.name.should eq("links")
    directive.series_key.value.should eq(42_u64)
    directive.bucket_range.from.value.should eq(20230201_u64)
    directive.bucket_range.to.value.should eq(20230203_u64)
  end
end
