<p align="center">
  <img src="https://raw.githubusercontent.com/creadone/karma/master/docs/karma.png" height="200">
  <h3 align="center">Karma</h3>
</p>

Karma is a small TCP database for hot time-series counters. It is designed for
cases where an application needs fresh pre-aggregated counters without hitting a
heavier analytical store on every request.

Typical use case:

```text
application reads link metadata
  -> application asks Karma for counters for many link ids
  -> client receives links with fresh click counters
```

Karma keeps data in memory, persists it with snapshots and WAL, and exposes a
newline-delimited JSON protocol over TCP.

Russian version: [README.ru.md](README.ru.md).

## Status

Karma is currently best understood as a production-oriented hot counter read
model, not as a general-purpose TSDB.

Supported today:

* day-bucketed counters with `YYYYMMDD` buckets;
* single-key writes and reads;
* batch reads and batch writes;
* streaming ingest for rebuild/backfill flows;
* atomic snapshots and WAL replay;
* recovery checkpoints and reconciliation reporting;
* async master -> slave replication through snapshot bootstrap and WAL polling;
* Prometheus-style operational metrics.

Important boundaries:

* command execution is serialized by one process-local state lock;
* replication is asynchronous and manual-failover only;
* there is no automatic leader election, quorum, or master-master mode;
* object-storage snapshot transport and `replication.subscribe` are not part of
  the current implementation.

For production use, run with a persistent volume, WAL enabled,
`--wal-fsync=true`, health checks, metrics scraping, and regular
`snapshot.create_all` or `SIGUSR1` snapshots.

## Build

Requirements:

* Crystal 1.17.1
* Shards

Build:

```sh
shards build --release
```

The binary is created at:

```sh
bin/karma
```

## Docker

Build:

```sh
docker build -t karma:local .
```

Run:

```sh
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

## Run

Recommended master node:

```sh
bin/karma \
  --bind=0.0.0.0 \
  --port=8080 \
  --directory=/var/lib/karma \
  --role=master \
  --restore=true \
  --wal=true \
  --wal-fsync=true \
  --auth-token=write-secret \
  --read-auth-token=read-secret
```

The same configuration can be provided through environment variables. Command
line options are applied after environment variables and override them:

```sh
KARMA_HOST=0.0.0.0 \
KARMA_PORT=8080 \
KARMA_DUMP_DIR=/var/lib/karma \
KARMA_RESTORE=true \
KARMA_WAL=true \
KARMA_WAL_FSYNC=true \
bin/karma
```

## Configuration

Boolean values use `true` or `false`. Timeout values use seconds unless the
option name ends with `-ms`.

| CLI option | Env var | Default | Description |
| --- | --- | ---: | --- |
| `--bind=host` | `KARMA_HOST` | `0.0.0.0` | Host to bind. |
| `--port=port` | `KARMA_PORT` | `8080` | TCP port. |
| `--directory=path` | `KARMA_DUMP_DIR` | `.` | Directory for snapshots, WAL, and metadata. |
| `--role=master\|slave` | `KARMA_ROLE` | `master` | Node role. |
| `--restore=true\|false` | `KARMA_RESTORE` | `true` | Restore snapshots and replay WAL on startup. |
| `--nodelay=true\|false` | `KARMA_TCP_NODELAY` | `true` | Enable TCP_NODELAY. |
| `--wal=true\|false` | `KARMA_WAL` | `true` | Persist mutating commands to WAL. |
| `--wal-fsync=true\|false` | `KARMA_WAL_FSYNC` | `true` | Fsync every WAL append/truncate. |
| `--wal-segment-bytes=bytes` | `KARMA_WAL_SEGMENT_BYTES` | `67108864` | Rotate the active WAL after this many bytes. Use 0 to disable rotation. |
| `--max-request-bytes=bytes` | `KARMA_MAX_REQUEST_BYTES` | `4096` | Maximum JSON request line size. Must be greater than 0. |
| `--max-response-bytes=bytes` | `KARMA_MAX_RESPONSE_BYTES` | `1048576` | Maximum JSON response size. Use 0 to disable. |
| `--read-timeout=seconds` | `KARMA_READ_TIMEOUT_SECONDS` | `5` | Client socket read timeout. Use 0 to disable. |
| `--write-timeout=seconds` | `KARMA_WRITE_TIMEOUT_SECONDS` | `5` | Client socket write timeout. Use 0 to disable. |
| `--query-timeout-ms=ms` | `KARMA_QUERY_TIMEOUT_MS` | `1000` | Timeout for expensive tree-level reads. Use 0 to disable. |
| `--shutdown-timeout=seconds` | `KARMA_SHUTDOWN_TIMEOUT_SECONDS` | `5` | Graceful shutdown drain timeout. |
| `--auth-token=token` | `KARMA_AUTH_TOKEN` | unset | Token required for all commands. Empty env value disables it. |
| `--read-auth-token=token` | `KARMA_READ_AUTH_TOKEN` | unset | Token allowed only for read-only commands. Empty env value disables it. |
| `--dump-retention-per-tree=count` | `KARMA_DUMP_RETENTION_PER_TREE` | `5` | Snapshots to keep per series after `snapshot.create_all`. |
| `--idempotency-max-records=count` | `KARMA_IDEMPOTENCY_MAX_RECORDS` | `1000000` | Maximum remembered idempotency write records. |
| `--idempotency-max-age-seconds=seconds` | `KARMA_IDEMPOTENCY_MAX_AGE_SECONDS` | `604800` | Maximum idempotency record age. Use 0 to disable age pruning. |
| `--replication-source-host=host` | `KARMA_REPLICATION_SOURCE_HOST` | unset | Master host used by slave polling. |
| `--replication-source-port=port` | `KARMA_REPLICATION_SOURCE_PORT` | `8080` | Master port used by slave polling. |
| `--replication-token=token` | `KARMA_REPLICATION_TOKEN` | unset | Token used by slave replication requests. |
| `--replication-poll-interval-ms=ms` | `KARMA_REPLICATION_POLL_INTERVAL_MS` | `1000` | Slave polling interval. |
| `--replication-batch-size=count` | `KARMA_REPLICATION_BATCH_SIZE` | `1000` | Maximum WAL entries fetched by one slave poll. Max: 10000. |
| `--log=true\|false` | `KARMA_LOG` | `true` | Emit structured JSON logs. |

## Protocol

Karma speaks newline-delimited JSON over TCP:

* one request is one JSON object followed by `\n`;
* one response is one JSON object followed by `\r\n`.

Protocol v2 is the preferred protocol for new clients. It uses `v: 2`,
namespaced `op` values, and `series/key/bucket/value` terminology:

```json
{"v":2,"op":"counter.increment","series":"links","key":42,"bucket":20260505,"value":1}
```

The legacy v1 protocol remains supported for compatibility and WAL replay.
Legacy requests use `command`, `tree_name`, `date`, and `time_from`/`time_to`.
New clients should use v2.

Response:

```json
{
  "protocol_version": 2,
  "success": true,
  "response": "OK",
  "error_code": null
}
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

* `invalid_json`
* `unknown_command`
* `validation_error`
* `not_found`
* `unauthorized`
* `forbidden`
* `request_too_large`
* `response_too_large`
* `query_timeout`
* `idempotency_conflict`
* `replication_gap`
* `replication_error`
* `internal_error`

If `--auth-token` is configured, include `token` in every client request. If
`--read-auth-token` is configured, that token can execute read-only commands
only. Tokens are not written to WAL.

## Idempotency

Write commands can include an optional `idempotency_key`. Karma records the
first successful request fingerprint and response for that key. Repeating the
same command with the same key and payload returns the saved response with
top-level `"idempotent": true` and does not mutate counters again. Reusing a
key with a different payload returns `idempotency_conflict`.

Eligible commands:

* `counter.increment`, `counter.decrement`;
* `series.batch_add`, `series.batch_set`;
* `counter.reset`, `counter.batch_reset`;
* `counter.delete_range`, `counter.batch_delete_range`;
* `tree.reset`, `tree.delete_range`.

Example:

```json
{"v":2,"op":"counter.increment","series":"links","key":42,"bucket":20260505,"value":1,"idempotency_key":"click-event-123"}
```

The response envelope includes `idempotent: false` for the first successful
idempotent write and `idempotent: true` for a deduplicated repeat.

Invalid requests do not occupy the key. The fingerprint is computed on the
server from the canonical command payload and ignores `v`, `token`,
`idempotency_key`, and `fingerprint`. Batch item order is part of the
fingerprint. Clients may pass `fingerprint` only as an assertion; it must match
the server-computed value.

Idempotency records are persisted through WAL and `snapshot.create_all`.
Retention is controlled by `--idempotency-max-records`,
`--idempotency-max-age-seconds`, and the manual prune command:

```json
{"v":2,"op":"idempotency.prune","before":"2026-05-29T00:00:00Z","limit":10000}
```

Streaming ingest is idempotent by `stream_id`: after `ingest.commit`, repeated
`ingest.commit`, compatible `ingest.begin`, and identical committed chunks are
reported as already committed/skipped without applying data again. A committed
stream with different parameters or chunks returns `idempotency_conflict`.

## Ruby/Rails Client

A Ruby client package is available in [clients/ruby](clients/ruby). It uses the
v2 TCP JSON protocol, has explicit connect/read/write timeouts, maps stable
Karma error codes to Ruby exceptions, and includes Rails configuration and a
small connection pool for Puma/Sidekiq workloads.

Rails applications can add it from this repository:

```ruby
gem "karma_client", path: "clients/ruby"
```

## Data Model

* A **series** is a named collection of counters. The storage layer and legacy
  API still use the word `tree`.
* A **key** is an unsigned 64-bit integer inside a series.
* A **bucket** is a UTC day in `YYYYMMDD` format, for example `20260505`.
* A **value** is an unsigned 64-bit integer.
* Increment/decrement commands use today's UTC bucket when `bucket` is omitted.
* Counter values never go below zero.

Read commands do not create missing series. Missing series return `not_found`.
For an existing series, reading a missing key returns zero or an empty result.

## Command Examples

### Basic Counters

Create a series:

```json
{"v":2,"op":"tree.create","series":"links"}
```

Increment today's counter:

```json
{"v":2,"op":"counter.increment","series":"links","key":42,"value":1}
```

Increment an explicit bucket:

```json
{"v":2,"op":"counter.increment","series":"links","key":42,"bucket":20260505,"value":1}
```

Decrement:

```json
{"v":2,"op":"counter.decrement","series":"links","key":42,"bucket":20260505,"value":1}
```

Read a key total:

```json
{"v":2,"op":"counter.sum","series":"links","key":42}
```

Read a date range:

```json
{"v":2,"op":"counter.sum","series":"links","key":42,"range":{"from":20260501,"to":20260505}}
```

Read daily points:

```json
{"v":2,"op":"counter.series","series":"links","key":42,"range":{"from":20260501,"to":20260505}}
```

### Batch Reads and Writes

Read many totals in one request:

```json
{"v":2,"op":"counter.batch_sum","series":"links","keys":[41,42,43]}
```

Read many totals for a range:

```json
{"v":2,"op":"counter.batch_sum","series":"links","keys":[41,42,43],"range":{"from":20260501,"to":20260505}}
```

Read totals across several series in one request:

```json
{"v":2,"op":"counter.multi_sum","items":[{"series":"links","key":101},{"series":"domains","key":101},{"series":"pixels","key":101}]}
{"v":2,"op":"counter.multi_sum","range":{"from":20260501,"to":20260531},"items":[{"series":"imports","key":101},{"series":"exports","key":101}]}
```

Add many `[key, bucket, value]` items:

```json
{"v":2,"op":"series.batch_add","series":"links","items":[[42,20260505,10],[43,20260505,3]]}
```

Set exact `[key, bucket, value]` items. A zero value deletes that bucket:

```json
{"v":2,"op":"series.batch_set","series":"links","items":[[42,20260505,10],[43,20260505,0]]}
```

Large batch requests must fit `--max-request-bytes`.

### Tree/Series Inspection

List series:

```json
{"v":2,"op":"tree.list"}
```

Inspect one series:

```json
{"v":2,"op":"tree.info","series":"links"}
```

Return keys with cursor pagination:

```json
{"v":2,"op":"tree.keys","series":"links","limit":1000,"cursor":0}
```

Return top keys:

```json
{"v":2,"op":"tree.top","series":"links","limit":100}
```

Return summary:

```json
{"v":2,"op":"tree.summary","series":"links","range":{"from":20260501,"to":20260505}}
```

### Retention and Maintenance

Delete old buckets:

```json
{"v":2,"op":"series.delete_before","series":"links","before":20260401}
```

Compact a series:

```json
{"v":2,"op":"series.compact","series":"links"}
```

Compact all series:

```json
{"v":2,"op":"system.compact"}
```

Reset one key or a whole series:

```json
{"v":2,"op":"counter.reset","series":"links","key":42}
{"v":2,"op":"tree.reset","series":"links"}
{"v":2,"op":"counter.batch_reset","series":"links","keys":[41,42,43]}
```

Delete a date range:

```json
{"v":2,"op":"counter.delete_range","series":"links","key":42,"range":{"from":20260501,"to":20260505}}
{"v":2,"op":"tree.delete_range","series":"links","range":{"from":20260501,"to":20260505}}
{"v":2,"op":"counter.batch_delete_range","series":"links","keys":[41,42,43],"range":{"from":20260501,"to":20260505}}
```

### Streaming Ingest

Streaming ingest is useful for rebuilds, backfills, and large imports. Supported
modes:

* `add`: add item values to the live series;
* `set`: set item bucket values in the live series;
* `replace_series`: build a staged series and atomically replace the live
  series on commit.

Example:

```json
{"v":2,"op":"ingest.begin","stream_id":"import-20260505","mode":"add","granularity":"day"}
{"v":2,"op":"ingest.chunk","stream_id":"import-20260505","series":"links","chunk_seq":1,"items":[[42,20260505,10]]}
{"v":2,"op":"ingest.commit","stream_id":"import-20260505"}
```

Abort an active stream:

```json
{"v":2,"op":"ingest.abort","stream_id":"import-20260505"}
```

Duplicate chunks are skipped. Out-of-order chunks are rejected before they are
applied. A stream is bound to the series used by its first chunk. Committed
streams are remembered durably so a repeated `replace_series` commit cannot
replace the series again after restart, snapshot restore, or replication
bootstrap.

## Snapshots, WAL, and Recovery

Karma uses two persistence mechanisms:

* snapshots: MessagePack `.tree` files, one per series;
* WAL: newline-delimited JSON entries in `karma.wal`.

By default the active WAL rotates at 64 MiB. Rotated WAL files are named
`karma.wal.<first_lsn>.segment` and are replayed before the active `karma.wal`.
Each segment gets a sidecar `*.segment.idx` file with `LSN -> byte offset`
entries. Replication uses these indexes to jump directly to the requested LSN
instead of scanning old WAL data. If an index is missing, stale, or points to an
invalid line boundary, Karma falls back to scanning the segment. Set
`--wal-segment-bytes=0` to keep the legacy single-file WAL behavior.

Create and inspect snapshots:

```json
{"v":2,"op":"snapshot.create","series":"links"}
{"v":2,"op":"snapshot.create_all"}
{"v":2,"op":"snapshot.list"}
{"v":2,"op":"snapshot.info"}
```

Load and fetch snapshots:

```json
{"v":2,"op":"snapshot.load","file":"1777925811_links.tree"}
{"v":2,"op":"snapshot.fetch","file":"1777925811_links.tree"}
{"v":2,"op":"snapshot.fetch_chunk","file":"1777925811_links.tree","offset":0,"limit":262144}
```

Verify the restore path:

```json
{"v":2,"op":"snapshot.verify"}
```

`snapshot.verify` restores data into a temporary cluster and checks:

* snapshot sidecar metadata;
* latest snapshot `last_lsn` consistency;
* WAL LSN continuity;
* snapshot/WAL boundaries;
* persisted `karma.wal.lsn`.

New WAL lines use an LSN envelope:

```json
{"v":2,"lsn":1,"entry":{"v":2,"op":"counter.increment","tree":"links","key":42,"date":20260505,"value":1}}
```

Each new snapshot has a sidecar metadata file named
`<snapshot>.meta.json`. It records `file`, `tree`, `timestamp`, `bytes`, and
`last_lsn`.

Startup with `--restore=true`:

1. Load the latest snapshot per series.
2. Replay WAL entries.
3. On slave nodes, initialize `karma.replication.lsn` from snapshot metadata
   before polling the master.

`snapshot.create_all` writes atomic snapshots, fsyncs them, truncates WAL after
successful snapshotting, and prunes old snapshots according to
`--dump-retention-per-tree`.

Recovery checkpoints can record external source positions such as ClickHouse
export ids or durable queue offsets:

```json
{"v":2,"op":"recovery.checkpoint","source":"clickhouse-links","offset":"export-2026-05-05","event_id":"batch-42"}
{"v":2,"op":"recovery.status"}
{"v":2,"op":"recovery.status","source":"clickhouse-links"}
```

External reconciliation jobs can report drift back to Karma:

```json
{"v":2,"op":"reconciliation.report","checked_points":1000,"mismatch_count":2,"absolute_drift":15,"max_abs_delta":10}
```

## Replication

Karma supports async master -> slave replication through snapshot bootstrap and
WAL polling.

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

If the slave data directory has no local snapshots and `--restore=true`, the
slave fetches the latest master snapshots through `snapshot.fetch_chunk`, sets
`karma.replication.lsn` from snapshot metadata, and then polls
`replication.entries`.

Useful commands:

```json
{"v":2,"op":"replication.status"}
{"v":2,"op":"replication.entries","after_lsn":120,"limit":1000}
```

`replication.entries` is bounded by both `limit` and the master's
`max_response_bytes`. If the byte budget cuts the page, the response includes
`truncated_by_bytes: true`, and `next_lsn` points to the last returned entry.

Operational notes:

* slave nodes reject direct mutating client commands;
* failover is manual;
* stop the old master before promoting a slave;
* rebuild remaining slaves from the promoted master;
* watch `karma_replication_lag_entries`,
  `karma_replication_poll_errors_total`, and
  `karma_replication_last_poll_success_unix`.

Detailed runbook: [docs/replication-operations-runbook.md](docs/replication-operations-runbook.md).

## Metrics and Health

Basic health:

```json
{"v":2,"op":"system.ping"}
{"v":2,"op":"system.health"}
```

Operational stats:

```json
{"v":2,"op":"system.stats"}
```

Prometheus-style metrics:

```json
{"v":2,"op":"system.metrics"}
```

Metric groups include:

* uptime, role, memory, trees, keys, snapshots;
* WAL bytes and current LSN;
* command counts, errors, latency, and protocol v1 usage;
* batch read/write counters;
* retention and compaction counters;
* ingest stream counters and latency;
* idempotency record, hit, conflict, prune, and committed ingest stream
  counters;
* reconciliation and recovery counters;
* replication lag, replayed LSN, polling/bootstrap success and error counters.

## Client Examples

Using `nc`:

```sh
printf '{"v":2,"op":"counter.increment","series":"links","key":42,"value":1}\n' | nc 127.0.0.1 8080
printf '{"v":2,"op":"counter.sum","series":"links","key":42}\n' | nc 127.0.0.1 8080
```

Using Crystal:

```crystal
require "json"
require "socket"

socket = TCPSocket.new("127.0.0.1", 8080)
socket << {v: 2, op: "counter.increment", series: "links", key: 42_u64, value: 1_u64}.to_json << "\n"
puts socket.gets
socket.close
```

Using Ruby:

```ruby
require "json"
require "socket"

socket = TCPSocket.new("127.0.0.1", 8080)
socket.write({v: 2, op: "counter.sum", series: "links", key: 42}.to_json + "\n")
puts socket.gets
socket.close
```

## Performance Checks

Local results depend on CPU, disk, filesystem, container runtime, network, and
workload mix. The scripts below are intended as repeatable local checks, not as
universal benchmarks.

Last recorded local results from 2026-06-05. Treat these as local regression
checks; short microbenchmarks can move by double-digit percentages between
runs on the same machine.

| Test | Mode | Throughput | p95 latency |
| --- | --- | ---: | ---: |
| `single_increment` | in-process, WAL off | 256,822 ops/sec | 0.0043 ms |
| `single_sum` | in-process, WAL off | 341,780 ops/sec | 0.0032 ms |
| `series.batch_add` | in-process, WAL off | 1,688,429 items/sec | 1.2420 ms |
| `counter.batch_sum` | in-process, WAL off | 2,165,827 key reads/sec | 1.0535 ms |
| `tcp_single_increment` | TCP, 4 clients, WAL off | 31,177 ops/sec | 0.1833 ms |
| `tcp_single_sum` | TCP, 4 clients, WAL off | 33,765 ops/sec | 0.1537 ms |
| `tcp_series.batch_add` | TCP, 4 clients, WAL off | 1,193,062 items/sec | 2.4643 ms |
| `tcp_counter.batch_sum` | TCP, 4 clients, WAL off | 1,859,901 key reads/sec | 2.6600 ms |
| `tcp_single_increment` | TCP, 4 clients, WAL on, fsync off | 10,833 ops/sec | 0.6422 ms |
| `tcp_single_sum` | TCP, 4 clients, WAL on, fsync off | 36,587 ops/sec | 0.1474 ms |
| `tcp_series.batch_add` | TCP, 4 clients, WAL on, fsync off | 1,020,590 items/sec | 2.7206 ms |
| `tcp_counter.batch_sum` | TCP, 4 clients, WAL on, fsync off | 1,712,127 key reads/sec | 4.5072 ms |

Idempotency hot-path spot check, in-process, WAL off, prebuilt JSON requests:
`counter.increment` without `idempotency_key` handled about 416,216 ops/sec;
with unique `idempotency_key`, about 213,745 ops/sec. For high-throughput
at-least-once producers, prefer `series.batch_add` so the idempotency overhead
is amortized across many items.

Volume sensitivity test, in-process, WAL off, 7 daily buckets per key:

| Keys | Data points | Heap | Snapshot | Batch sum | Batch p95 | Summary | Snapshot | Restore |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 10,000 | 70,000 | 8.02 MiB | 0.57 MiB | 2,302,852 key reads/sec | 0.8223 ms | 3.85 ms | 3.30 ms | 2.76 ms |
| 50,000 | 350,000 | 27.80 MiB | 2.86 MiB | 1,143,466 key reads/sec | 2.1352 ms | 37.21 ms | 27.35 ms | 17.56 ms |
| 100,000 | 700,000 | 48.44 MiB | 5.79 MiB | 1,423,217 key reads/sec | 0.4478 ms | 80.40 ms | 40.20 ms | 32.10 ms |

High-cardinality yearly profile, in-process, WAL off, 356 daily buckets per key:

| Keys | Data points | Heap | Snapshot | Batch sum | Batch p95 | Summary | Snapshot | Restore |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 10,000 | 3,560,000 | 239.30 MiB | 20.58 MiB | 2,277,821 key reads/sec | 4.1174 ms | 137.72 ms | 77.19 ms | 114.27 ms |
| 25,000 | 8,900,000 | 559.33 MiB | 51.45 MiB | 2,148,006 key reads/sec | 2.2384 ms | 404.00 ms | 201.22 ms | 282.08 ms |
| 50,000 | 17,800,000 | 1,119.38 MiB | 102.90 MiB | 1,909,754 key reads/sec | 2.6850 ms | 985.17 ms | 434.92 ms | 618.38 ms |

Replication load test on the same date used `clients=4`, `keys=10000`,
`batch_size=1000`, `write_batches=100`, `read_rounds=100`,
`replication_poll_interval_ms=10`, and `replication_batch_size=1000`.
The slave bootstrapped from snapshot, replayed WAL from LSN 10 to LSN 110,
ended with `final_lag_entries=0`, and matched the master total:
`master_total=110000`, `slave_total=110000`.
The mixed read/write phase handled about 807,117 operations/sec on both the
master write stream and slave read stream.

WAL paging spot checks used `limit=1000`. The short 100,000-entry benchmark
does not cross the default 64 MiB segment boundary: cold page read was 2.06 ms,
hot p50/p95 was 1.7303/2.0745 ms, and sequential catch-up read about 569,364
entries/sec. A 1,000,000-entry segmented run read a cold page from a sidecar
indexed segment in 80.73 ms versus 267.28 ms without the sidecar index, a 3.31x
speedup; hot p50/p95 was 1.8247/2.2133 ms.

In-process command-layer test:

```sh
crystal build --release scripts/load_test.cr -o bin/karma_load_test
bin/karma_load_test
```

TCP loopback test:

```sh
crystal build --release scripts/tcp_load_test.cr -o bin/karma_tcp_load_test
bin/karma_tcp_load_test \
  --clients=4 \
  --wal=true \
  --wal-fsync=false
```

Volume sensitivity test:

```sh
crystal build --release scripts/volume_load_test.cr -o bin/karma_volume_load_test
bin/karma_volume_load_test \
  --sizes=10000,50000,100000 \
  --bucket-count=7 \
  --batch-size=1000 \
  --single-rounds=1000 \
  --read-rounds=100
```

High-cardinality yearly profile with 356 buckets per key:

```sh
bin/karma_volume_load_test --profile=year-356
```

Master/slave replication test:

```sh
shards build --release
crystal build --release scripts/replication_load_test.cr -o bin/karma_replication_load_test
bin/karma_replication_load_test \
  --binary=bin/karma \
  --clients=4 \
  --keys=10000 \
  --batch-size=1000 \
  --write-batches=100 \
  --read-rounds=100
```

WAL paging benchmark for replication catch-up and tail polling:

```sh
crystal run --release scripts/wal_page_bench.cr -- \
  --entries=100000 \
  --limit=1000 \
  --tail-rounds=20 \
  --segment-bytes=67108864 \
  --after-lsn=10000 \
  --compare-sidecar \
  --skip-linear
```

CSV reconciliation against exported aggregates:

```sh
crystal run scripts/reconcile_csv.cr -- \
  --host=127.0.0.1 \
  --port=8080 \
  --series=links \
  --csv=clickhouse-links.csv \
  --report
```

## Signals

* `SIGINT`: stop accepting new TCP clients, dump all series, truncate WAL after
  successful snapshots, and exit with status 0.
* `SIGUSR1`: dump all series, truncate WAL after successful snapshots, and keep
  running.

## Development

Run tests:

```sh
crystal spec
crystal spec lib/counter_tree/spec
```

Build:

```sh
shards build --release
```

The `counter_tree` library is vendored in `lib/counter_tree`, so counter storage
changes can be developed and tested inside this repository.

## License

MIT
