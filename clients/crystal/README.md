# Karma Crystal Client

Crystal client for Karma's v2 TCP JSON protocol.

The main use case is storing and reading limit usage. A Karma `series` maps to a
limit name, `key` maps to the subject id, and `bucket` maps to the UTC day.

Examples:

* limit name: `api_requests`;
* subject id: account, user, workspace, or project id;
* amount: how much usage was consumed;
* day: UTC day in `YYYYMMDD`, `YYYY-MM-DD`, or `Time`.

## Installation

From this repository:

```yaml
dependencies:
  karma_client:
    path: clients/crystal
```

Then:

```crystal
require "karma_client"
```

## Configuration

```crystal
KarmaClient.configure do |config|
  config.host = ENV.fetch("KARMA_HOST", "127.0.0.1")
  config.port = ENV.fetch("KARMA_PORT", "8080").to_i
  config.token = ENV["KARMA_TOKEN"]? || ENV["KARMA_AUTH_TOKEN"]?
  config.connect_timeout = 0.5.seconds
  config.read_timeout = 0.5.seconds
  config.write_timeout = 0.5.seconds
  config.pool_size = 5
  config.pool_timeout = 0.2.seconds
end
```

Supported environment variables:

* `KARMA_URL`, for example `tcp://127.0.0.1:8080?token=secret`;
* `KARMA_HOST`;
* `KARMA_PORT`;
* `KARMA_TOKEN`, `KARMA_AUTH_TOKEN`, or `KARMA_READ_AUTH_TOKEN`;
* `KARMA_CONNECT_TIMEOUT`;
* `KARMA_READ_TIMEOUT`;
* `KARMA_WRITE_TIMEOUT`;
* `KARMA_POOL_SIZE`;
* `KARMA_POOL_TIMEOUT`.

Timeout environment variables are seconds and may be fractional.

## Limit Usage

Use the pool in web handlers and background jobs:

```crystal
KarmaClient.with_client do |karma|
  karma.create_limit("api_requests")

  karma.record_usage(
    "api_requests",
    subject_id: 42,
    amount: 1,
    day: Time.utc,
    idempotency_key: "usage-event-123"
  )

  used = karma.usage(
    "api_requests",
    subject_id: 42,
    from: "2026-05-01",
    to: "2026-05-31"
  )
end
```

Batch reads return a typed hash:

```crystal
usage = KarmaClient.with_client do |karma|
  karma.batch_usage("api_requests", [41, 42, 43])
end

# => {41_u64 => 10_u64, 42_u64 => 15_u64, ...}
```

Batch writes are useful when the application already aggregated usage events:

```crystal
KarmaClient.with_client do |karma|
  karma.record_usage_batch(
    "api_requests",
    [
      {41, "2026-05-05", 10},
      {42, "2026-05-05", 15},
    ],
    idempotency_key: "usage-import-20260505"
  )
end
```

Set exact usage for a day:

```crystal
KarmaClient.with_client do |karma|
  karma.set_usage("api_requests", subject_id: 42, amount: 100, day: "2026-05-05")
end
```

The client never retries mutating commands automatically. For retryable write
workflows, pass a stable `idempotency_key` derived from the source event or job.

## Protocol Methods

The client also exposes protocol-level methods:

```crystal
karma = KarmaClient::Client.new(host: "127.0.0.1", port: 8080, token: ENV["KARMA_TOKEN"]?)

karma.increment(series: "api_requests", key: 42, bucket: "2026-05-05", value: 1)
karma.sum(series: "api_requests", key: 42, from: "2026-05-01", to: "2026-05-31")
karma.batch_sum(series: "api_requests", keys: [41, 42, 43])
karma.health

karma.close
```

Every v2 operation is available through `call`:

```crystal
KarmaClient.with_client do |karma|
  karma.call("tree.keys", series: "api_requests", limit: 1000, cursor: 0)
end
```

Use `request` when you need the raw response envelope:

```crystal
response = KarmaClient.with_client do |karma|
  karma.request(
    "counter.increment",
    series: "api_requests",
    key: 42,
    bucket: Time.utc,
    value: 1,
    idempotency_key: "usage-event-123"
  )
end

response.success?
response.value
response.error_code
response.idempotent?
```

## Errors

Server-side errors raise `KarmaClient::ServerError` subclasses:

```crystal
begin
  KarmaClient.with_client { |karma| karma.usage("api_requests", 42) }
rescue ex : KarmaClient::NotFoundError
  # Limit series does not exist.
rescue ex : KarmaClient::ServerError
  # ex.code and ex.retriable? are available.
end
```

Transport and local validation errors are separate:

* `KarmaClient::ConnectionError`;
* `KarmaClient::TimeoutError`;
* `KarmaClient::InputError`;
* `KarmaClient::ProtocolError`;
* `KarmaClient::PoolTimeout`.

