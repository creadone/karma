# Karma

Karma is a small TCP service for high-throughput, day-bucketed counters.

Use it when an application needs fresh totals for many ids on every request and
an analytical database is too heavy for that hot path. Karma keeps counters in
memory, persists accepted writes through snapshots and a write-ahead log (WAL),
and speaks newline-delimited JSON over TCP.

Russian version: [README.ru.md](README.ru.md).

## What It Is For

Typical flow:

```text
application loads business objects
  -> application asks Karma for counters by id
  -> response returns fresh pre-aggregated totals
```

Karma is a focused read model for counters, not a general-purpose time-series
database.

It supports:

* unsigned 64-bit counters grouped by series, key, and UTC day bucket;
* single and batch reads/writes;
* idempotent writes for at-least-once producers;
* large rebuilds through streaming ingest;
* snapshots, WAL replay, and restore verification;
* asynchronous master-to-slave replication by snapshot bootstrap and WAL polling;
* health, statistics, and Prometheus-style metrics.

It does not provide automatic leader election, quorum writes, multi-master
replication, arbitrary time-series tags, or ad-hoc analytical queries.

## Quick Start

Requirements:

* Crystal 1.17.1
* Shards

Build and run:

```sh
shards build --release
bin/karma \
  --bind=127.0.0.1 \
  --port=8080 \
  --directory=.karma-data \
  --restore=true \
  --wal=true
```

Write and read a counter:

```sh
printf '{"v":2,"op":"counter.increment","series":"links","key":42,"value":1}\n' \
  | nc 127.0.0.1 8080

printf '{"v":2,"op":"counter.sum","series":"links","key":42}\n' \
  | nc 127.0.0.1 8080
```

Response envelope:

```json
{"protocol_version":2,"success":true,"response":1,"error_code":null}
```

With Docker:

```sh
docker build -t karma:local .
docker run --rm \
  -p 8080:8080 \
  -v karma-data:/data \
  karma:local \
  --bind=0.0.0.0 \
  --port=8080 \
  --directory=/data \
  --restore=true \
  --wal=true \
  --wal-fsync=true
```

For production, use a persistent volume, WAL enabled, `--wal-fsync=true`,
health checks, metrics scraping, and regular `snapshot.create_all` or `SIGUSR1`
snapshots.

## Data Model

| Term | Meaning |
| --- | --- |
| `series` | Named counter collection, for example `links` or `domains`. |
| `key` | Unsigned 64-bit id inside a series. |
| `bucket` | UTC day in `YYYYMMDD` format. If omitted on writes, Karma uses today's UTC bucket. |
| `value` | Unsigned 64-bit amount. Counters never go below zero. |

Read commands never create missing series. A missing series returns `not_found`;
a missing key inside an existing series returns zero or an empty result.

## Protocol

Karma 1.0 accepts only protocol v2 requests:

* one request is one JSON object followed by `\n`;
* one response is one JSON object followed by `\r\n`;
* every request must include `"v": 2` and an `op` field.

Example:

```json
{"v":2,"op":"counter.increment","series":"links","key":42,"bucket":20260505,"value":1}
```

Error response:

```json
{
  "protocol_version": 2,
  "success": false,
  "response": "Field tree or series is required",
  "error_code": "validation_error"
}
```

Stable error codes:

| Code | Meaning |
| --- | --- |
| `invalid_json` | Request body is not valid JSON. |
| `unsupported_protocol` | Request is not protocol v2. |
| `unknown_command` | `op` is unknown. |
| `validation_error` | Request shape or value is invalid. |
| `not_found` | Requested series or file does not exist. |
| `unauthorized` | Token is missing or invalid. |
| `forbidden` | Command is not allowed for the node role or token. |
| `request_too_large` | Request exceeds `--max-request-bytes`. |
| `response_too_large` | Response exceeds `--max-response-bytes`. |
| `query_timeout` | A large read exceeded `--query-timeout-ms`. |
| `idempotency_conflict` | Idempotency key was reused with different payload. |
| `replication_gap` | Requested WAL range is no longer available. |
| `replication_error` | Replication bootstrap or polling failed. |
| `internal_error` | Unexpected server-side exception. |

If `--auth-token` is set, every client request must include `token`. If
`--read-auth-token` is set, that token can run read-only commands. Tokens are
never written to the WAL.

## Common Operations

### Counters

```json
{"v":2,"op":"tree.create","series":"links"}
{"v":2,"op":"counter.increment","series":"links","key":42,"value":1}
{"v":2,"op":"counter.increment","series":"links","key":42,"bucket":20260505,"value":10}
{"v":2,"op":"counter.decrement","series":"links","key":42,"bucket":20260505,"value":1}
{"v":2,"op":"counter.sum","series":"links","key":42}
{"v":2,"op":"counter.sum","series":"links","key":42,"range":{"from":20260501,"to":20260505}}
{"v":2,"op":"counter.series","series":"links","key":42,"range":{"from":20260501,"to":20260505}}
```

### Batch Reads and Writes

```json
{"v":2,"op":"counter.batch_sum","series":"links","keys":[41,42,43]}
{"v":2,"op":"counter.batch_sum","series":"links","keys":[41,42,43],"range":{"from":20260501,"to":20260505}}
{"v":2,"op":"counter.multi_sum","items":[{"series":"links","key":101},{"series":"domains","key":101}]}
{"v":2,"op":"series.batch_add","series":"links","items":[[42,20260505,10],[43,20260505,3]]}
{"v":2,"op":"series.batch_set","series":"links","items":[[42,20260505,10],[43,20260505,0]]}
```

`series.batch_set` writes exact bucket values. A zero value deletes that bucket.
Large requests must fit `--max-request-bytes`.

### Series Inspection and Maintenance

```json
{"v":2,"op":"tree.list"}
{"v":2,"op":"tree.info","series":"links"}
{"v":2,"op":"tree.keys","series":"links","limit":1000,"cursor":0}
{"v":2,"op":"tree.summary","series":"links","range":{"from":20260501,"to":20260505}}
{"v":2,"op":"tree.top","series":"links","limit":100}
{"v":2,"op":"series.delete_before","series":"links","before":20260401}
{"v":2,"op":"series.compact","series":"links"}
{"v":2,"op":"system.compact"}
```

### Deletes and Resets

```json
{"v":2,"op":"counter.reset","series":"links","key":42}
{"v":2,"op":"counter.batch_reset","series":"links","keys":[41,42,43]}
{"v":2,"op":"tree.reset","series":"links"}
{"v":2,"op":"counter.delete_range","series":"links","key":42,"range":{"from":20260501,"to":20260505}}
{"v":2,"op":"counter.batch_delete_range","series":"links","keys":[41,42,43],"range":{"from":20260501,"to":20260505}}
{"v":2,"op":"tree.delete_range","series":"links","range":{"from":20260501,"to":20260505}}
```

## Idempotent Writes

Mutating commands can include `idempotency_key`. Karma stores the first
successful response for that key. Repeating the same payload returns the saved
response with `"idempotent": true`; reusing the key with a different payload
returns `idempotency_conflict`.

Example:

```json
{"v":2,"op":"counter.increment","series":"links","key":42,"bucket":20260505,"value":1,"idempotency_key":"click-event-123"}
```

Eligible commands:

* `counter.increment`, `counter.decrement`;
* `series.batch_add`, `series.batch_set`;
* `counter.reset`, `counter.batch_reset`;
* `counter.delete_range`, `counter.batch_delete_range`;
* `tree.reset`, `tree.delete_range`.

Idempotency records are persisted through WAL and snapshots. Retention is
controlled by `--idempotency-max-records`, `--idempotency-max-age-seconds`, and:

```json
{"v":2,"op":"idempotency.prune","before":"2026-05-29T00:00:00Z","limit":10000}
```

## Streaming Ingest

Streaming ingest is for rebuilds, backfills, and large imports. Supported
modes:

| Mode | Behavior |
| --- | --- |
| `add` | Add item values to the live series. |
| `set` | Set exact item bucket values in the live series. |
| `replace_series` | Build a staged series and atomically replace the live series on commit. |

Example:

```json
{"v":2,"op":"ingest.begin","stream_id":"import-20260505","mode":"add","granularity":"day"}
{"v":2,"op":"ingest.chunk","stream_id":"import-20260505","series":"links","chunk_seq":1,"items":[[42,20260505,10]]}
{"v":2,"op":"ingest.commit","stream_id":"import-20260505"}
```

Abort:

```json
{"v":2,"op":"ingest.abort","stream_id":"import-20260505"}
```

Duplicate chunks are skipped. Out-of-order chunks are rejected before they are
applied. A stream is bound to the series used by its first chunk. Committed
streams are remembered durably, so a repeated `replace_series` commit cannot
replace the series again after restart, snapshot restore, or replication
bootstrap.

## Persistence and Recovery

Karma persists data through:

* snapshots: MessagePack `.tree` files, one per series;
* WAL: newline-delimited JSON entries in `karma.wal`.

The active WAL rotates at 64 MiB by default. Rotated files are named
`karma.wal.<first_lsn>.segment` and have optional `*.segment.idx` sidecar
indexes that map LSN to byte offset for fast replication catch-up.

Snapshot commands:

```json
{"v":2,"op":"snapshot.create","series":"links"}
{"v":2,"op":"snapshot.create_all"}
{"v":2,"op":"snapshot.list"}
{"v":2,"op":"snapshot.info"}
{"v":2,"op":"snapshot.verify"}
```

Fetch or load snapshots:

```json
{"v":2,"op":"snapshot.load","file":"1777925811_links.tree"}
{"v":2,"op":"snapshot.fetch","file":"1777925811_links.tree"}
{"v":2,"op":"snapshot.fetch_chunk","file":"1777925811_links.tree","offset":0,"limit":262144}
```

New WAL entries use a v2 LSN envelope:

```json
{"v":2,"lsn":1,"entry":{"v":2,"op":"counter.increment","series":"links","key":42,"bucket":20260505,"value":1}}
```

Startup with `--restore=true` loads the latest snapshot per series and replays
WAL entries after the snapshot LSN. `snapshot.create_all` writes atomic
snapshots, fsyncs them, truncates WAL after successful snapshotting, and prunes
old snapshots according to `--dump-retention-per-tree`.

Recovery markers for external pipelines:

```json
{"v":2,"op":"recovery.checkpoint","source":"clickhouse-links","offset":"export-2026-05-05","event_id":"batch-42"}
{"v":2,"op":"recovery.status"}
{"v":2,"op":"recovery.status","source":"clickhouse-links"}
{"v":2,"op":"reconciliation.report","checked_points":1000,"mismatch_count":2,"absolute_drift":15,"max_abs_delta":10}
```

## Replication

Karma supports asynchronous master-to-slave replication. A slave can bootstrap
from master snapshots and then poll WAL entries.

Start a slave:

```sh
bin/karma \
  --role=slave \
  --port=8081 \
  --directory=/var/lib/karma-slave \
  --restore=true \
  --replication-source-host=127.0.0.1 \
  --replication-source-port=8080 \
  --replication-token=read-secret
```

Useful requests:

```json
{"v":2,"op":"replication.status"}
{"v":2,"op":"replication.entries","after_lsn":120,"limit":1000}
```

Operational boundaries:

* replication is asynchronous;
* slave nodes reject direct mutating client commands;
* failover is manual;
* stop the old master before promoting a slave;
* rebuild remaining slaves from the promoted master.

Detailed runbook: [docs/replication-operations-runbook.md](docs/replication-operations-runbook.md).

## Configuration

Command-line options override environment variables. Boolean values are
`true`/`false`. Timeout values are seconds unless the option name ends with
`-ms`.

| Option | Environment | Default | Meaning |
| --- | --- | ---: | --- |
| `--bind=host` | `KARMA_HOST` | `0.0.0.0` | Address to listen on. |
| `--port=port` | `KARMA_PORT` | `8080` | TCP port. |
| `--directory=path` | `KARMA_DUMP_DIR` | `.` | Directory for snapshots, WAL, and metadata. |
| `--role=master\|slave` | `KARMA_ROLE` | `master` | Node role. |
| `--restore=true\|false` | `KARMA_RESTORE` | `true` | Restore snapshots and replay WAL on startup. |
| `--nodelay=true\|false` | `KARMA_TCP_NODELAY` | `true` | Enable TCP_NODELAY. |
| `--wal=true\|false` | `KARMA_WAL` | `true` | Persist mutating commands to WAL. |
| `--wal-fsync=true\|false` | `KARMA_WAL_FSYNC` | `true` | Fsync WAL writes and truncation. |
| `--wal-segment-bytes=bytes` | `KARMA_WAL_SEGMENT_BYTES` | `67108864` | Rotate active WAL after this many bytes; `0` disables rotation. |
| `--wal-batch-size=count` | `KARMA_WAL_BATCH_SIZE` | `1024` | Maximum WAL entries flushed by one writer batch. |
| `--wal-batch-wait-us=microseconds` | `KARMA_WAL_BATCH_WAIT_MICROSECONDS` | `0` | Maximum WAL writer wait for additional entries. |
| `--max-request-bytes=bytes` | `KARMA_MAX_REQUEST_BYTES` | `4096` | Maximum JSON request line size. |
| `--max-response-bytes=bytes` | `KARMA_MAX_RESPONSE_BYTES` | `1048576` | Maximum JSON response size; `0` disables the limit. |
| `--read-timeout=seconds` | `KARMA_READ_TIMEOUT_SECONDS` | `5` | Client socket read timeout; `0` disables it. |
| `--write-timeout=seconds` | `KARMA_WRITE_TIMEOUT_SECONDS` | `5` | Client socket write timeout; `0` disables it. |
| `--query-timeout-ms=ms` | `KARMA_QUERY_TIMEOUT_MS` | `1000` | Timeout for large reads; `0` disables it. |
| `--shutdown-timeout=seconds` | `KARMA_SHUTDOWN_TIMEOUT_SECONDS` | `5` | Graceful shutdown drain timeout. |
| `--auth-token=token` | `KARMA_AUTH_TOKEN` | unset | Token required for all commands. |
| `--read-auth-token=token` | `KARMA_READ_AUTH_TOKEN` | unset | Token allowed only for read-only commands. |
| `--dump-retention-per-tree=count` | `KARMA_DUMP_RETENTION_PER_TREE` | `5` | Snapshots to keep per series after `snapshot.create_all`. |
| `--idempotency-max-records=count` | `KARMA_IDEMPOTENCY_MAX_RECORDS` | `1000000` | Maximum remembered idempotency records. |
| `--idempotency-max-age-seconds=seconds` | `KARMA_IDEMPOTENCY_MAX_AGE_SECONDS` | `604800` | Maximum idempotency record age; `0` disables age pruning. |
| `--replication-source-host=host` | `KARMA_REPLICATION_SOURCE_HOST` | unset | Master host used by slave polling. |
| `--replication-source-port=port` | `KARMA_REPLICATION_SOURCE_PORT` | `8080` | Master port used by slave polling. |
| `--replication-token=token` | `KARMA_REPLICATION_TOKEN` | unset | Token used by slave replication requests. |
| `--replication-poll-interval-ms=ms` | `KARMA_REPLICATION_POLL_INTERVAL_MS` | `1000` | Slave polling interval. |
| `--replication-batch-size=count` | `KARMA_REPLICATION_BATCH_SIZE` | `1000` | Maximum WAL entries fetched by one slave poll. |
| `--log=true\|false` | `KARMA_LOG` | `true` | Emit structured JSON logs. |

## Health and Metrics

```json
{"v":2,"op":"system.ping"}
{"v":2,"op":"system.health"}
{"v":2,"op":"system.stats"}
{"v":2,"op":"system.metrics"}
```

Metrics include uptime, role, memory use, series/key counts, WAL size and LSN,
command counts and latency, batch counters, ingest counters, idempotency
counters, recovery/reconciliation counters, and replication lag/polling status.

Watch these in production:

* `karma_replication_lag_entries`
* `karma_replication_poll_errors_total`
* `karma_replication_last_poll_success_unix`
* `karma_errors_total`
* `karma_query_timeouts_total`

## Clients

Ruby/Rails client:

```ruby
gem "karma_client", path: "clients/ruby"
```

The client uses the v2 TCP JSON protocol, maps stable Karma error codes to Ruby
exceptions, supports explicit connect/read/write timeouts, and includes a small
connection pool for Puma/Sidekiq workloads.

Minimal Ruby request:

```ruby
require "json"
require "socket"

socket = TCPSocket.new("127.0.0.1", 8080)
socket.write({v: 2, op: "counter.sum", series: "links", key: 42}.to_json + "\n")
puts socket.gets
socket.close
```

## Performance Checks

Local results depend on CPU, disk, filesystem, runtime, network, and workload
mix. Treat these as local regression checks, not universal promises.

Last recorded local results: 2026-06-06.

| Test | Mode | Throughput | p95 latency |
| --- | --- | ---: | ---: |
| `single_increment` | in-process, WAL off | 390,785 ops/sec | 0.0026 ms |
| `single_sum` | in-process, WAL off | 568,529 ops/sec | 0.0019 ms |
| `series.batch_add` | in-process, WAL off | 2,288,199 items/sec | 1.1090 ms |
| `counter.batch_sum` | in-process, WAL off | 2,474,548 key reads/sec | 0.9126 ms |
| `tcp_single_increment` | TCP, 4 clients, WAL off | 36,728 ops/sec | 0.1580 ms |
| `tcp_single_sum` | TCP, 4 clients, WAL off | 40,614 ops/sec | 0.1278 ms |
| `tcp_series.batch_add` | TCP, 4 clients, WAL off | 1,457,823 items/sec | 2.5373 ms |
| `tcp_counter.batch_sum` | TCP, 4 clients, WAL off | 2,275,990 key reads/sec | 2.1863 ms |
| `tcp_single_increment` | TCP, 4 clients, WAL on, fsync off | 21,077 ops/sec | 0.2369 ms |
| `tcp_single_sum` | TCP, 4 clients, WAL on, fsync off | 37,927 ops/sec | 0.1458 ms |
| `tcp_series.batch_add` | TCP, 4 clients, WAL on, fsync off | 1,109,765 items/sec | 5.4988 ms |
| `tcp_counter.batch_sum` | TCP, 4 clients, WAL on, fsync off | 2,278,534 key reads/sec | 2.5800 ms |

Additional local checks from the same run:

* idempotent `counter.increment`, WAL off, prebuilt JSON: about 506,918 ops/sec
  without `idempotency_key`, about 205,914 ops/sec with unique keys;
* 100,000 keys with 7 buckets each: `counter.batch_sum` read about 1,505,471
  keys/sec;
* 50,000 keys with 356 buckets each: `counter.batch_sum` read about 1,946,673
  keys/sec;
* replication load test ended with zero lag and matching master/slave totals;
* a 1,000,000-entry segmented WAL read a cold page from an indexed segment in
  83.23 ms versus 253.36 ms without the sidecar index.

Reproduce the main checks:

```sh
crystal build --release scripts/load_test.cr -o bin/karma_load_test
bin/karma_load_test

crystal build --release scripts/tcp_load_test.cr -o bin/karma_tcp_load_test
bin/karma_tcp_load_test --clients=4 --wal=true --wal-fsync=false
```

More scripts are in [scripts](scripts).

## Signals

* `SIGINT`: stop accepting new TCP clients, snapshot all series, truncate WAL
  after successful snapshots, and exit with status 0.
* `SIGUSR1`: snapshot all series, truncate WAL after successful snapshots, and
  keep running.

## Development

```sh
crystal spec
crystal spec lib/counter_tree/spec
shards build --release
```

The `counter_tree` library is vendored in [lib/counter_tree](lib/counter_tree).

## License

MIT
