# Karma Ruby Client

Ruby/Rails client for Karma's v2 newline-delimited JSON TCP protocol.

The client is designed for Rails API applications and background workers:

* no runtime dependencies outside Ruby stdlib;
* lazy TCP connections, safe to initialize before Puma forks;
* per-request connect/read/write timeouts;
* a small connection pool for multi-threaded Rails and Sidekiq workloads;
* server error classes with stable `error_code` mapping;
* optional ActiveSupport notifications: `request.karma_client`.

## Installation

From this repository:

```ruby
gem "karma_client", path: "clients/ruby"
```

## Rails Configuration

Create `config/initializers/karma_client.rb`:

```ruby
KarmaClient.configure do |config|
  config.host = ENV.fetch("KARMA_HOST", "127.0.0.1")
  config.port = ENV.fetch("KARMA_PORT", 8080).to_i
  config.token = ENV["KARMA_TOKEN"] || ENV["KARMA_AUTH_TOKEN"]
  config.connect_timeout = 0.5
  config.read_timeout = 0.5
  config.write_timeout = 0.5
  config.pool_size = ENV.fetch("RAILS_MAX_THREADS", 5).to_i
  config.pool_timeout = 0.2
end
```

You can also configure it with Rails config:

```ruby
# config/application.rb
config.karma_client.host = ENV.fetch("KARMA_HOST", "127.0.0.1")
config.karma_client.port = ENV.fetch("KARMA_PORT", 8080).to_i
config.karma_client.token = ENV["KARMA_TOKEN"]
```

Supported environment variables:

* `KARMA_URL`, for example `tcp://127.0.0.1:8080`;
* `KARMA_HOST`;
* `KARMA_PORT`;
* `KARMA_TOKEN`, `KARMA_AUTH_TOKEN`, or `KARMA_READ_AUTH_TOKEN`;
* `KARMA_CONNECT_TIMEOUT`;
* `KARMA_READ_TIMEOUT`;
* `KARMA_WRITE_TIMEOUT`;
* `KARMA_POOL_SIZE`;
* `KARMA_POOL_TIMEOUT`.

## Usage

Use the pool in Rails request handlers and jobs:

```ruby
KarmaClient.with_client do |karma|
  karma.create_series("links")
  karma.increment(series: "links", key: 42, bucket: Date.current, value: 1)
  karma.sum(series: "links", key: 42, from: 7.days.ago.to_date, to: Date.current)
end
```

Batch reads:

```ruby
counts = KarmaClient.with_client do |karma|
  karma.batch_sum(series: "links", keys: [41, 42, 43])
end

# => [{"key"=>41, "value"=>10}, {"key"=>42, "value"=>15}, ...]
```

Multi-series reads:

```ruby
KarmaClient.with_client do |karma|
  karma.multi_sum(
    items: [
      { series: "links", key: 101 },
      { series: "domains", key: 101 }
    ],
    from: "2026-05-01",
    to: "2026-05-31"
  )
end
```

Streaming ingest:

```ruby
KarmaClient.with_client do |karma|
  karma.ingest_begin(stream_id: "import-20260505", mode: "add")
  karma.ingest_chunk(
    stream_id: "import-20260505",
    series: "links",
    chunk_seq: 1,
    items: [[42, "2026-05-05", 10]]
  )
  karma.ingest_commit(stream_id: "import-20260505")
end
```

For one-off scripts, instantiate a client directly:

```ruby
karma = KarmaClient::Client.new(host: "127.0.0.1", port: 8080, token: ENV["KARMA_TOKEN"])
karma.health
ensure
  karma&.close
```

## Errors

Server-side errors raise `KarmaClient::ServerError` subclasses:

```ruby
begin
  KarmaClient.with_client { |karma| karma.sum(series: "missing", key: 42) }
rescue KarmaClient::NotFoundError => e
  Rails.logger.info("karma_not_found", code: e.code, message: e.message)
rescue KarmaClient::ServerError => e
  Rails.logger.warn("karma_error", code: e.code, retriable: e.retriable?)
end
```

Transport and local validation errors are separate:

* `KarmaClient::ConnectionError`;
* `KarmaClient::TimeoutError`;
* `KarmaClient::InputError`;
* `KarmaClient::ProtocolError`;
* `KarmaClient::PoolTimeout`.

The client does not retry mutating commands automatically. Counter increments
are not idempotent unless your application adds its own idempotency layer.

## Generic Protocol Access

Every v2 operation is available through `call`:

```ruby
KarmaClient.with_client do |karma|
  karma.call("tree.keys", series: "links", limit: 1000, cursor: 0)
end
```

Use `request` when you need the raw envelope:

```ruby
response = KarmaClient.with_client do |karma|
  karma.request("system.health")
end

response.success?
response.value
response.error_code
```
