<p align="center">
  <img src="https://raw.githubusercontent.com/creadone/karma/master/docs/karma.png" height="200">
  <h3 align="center">Karma</h3>
</p>

Karma is a small TCP database for hot time-series counters with one-day
granularity. It stores named series, historically called trees. Each series
contains many numeric keys, and each key stores daily bucket values plus a
total.

Karma is useful when a service needs fast counters for limits, usage tracking,
or short-link click statistics:

* increment or decrement a counter for the current day;
* read a key total;
* read a key total for a date range;
* read daily values for a date range;
* snapshot data to disk and restore it with WAL replay.

## Status

Karma is designed as a single-node service. Data is kept in memory, persisted
with atomic `.tree` snapshots, and protected between snapshots by an append-only
write-ahead log (`karma.wal`). The current concurrency model serializes command
execution through one process-local state lock.

For critical production use, run it with a persistent volume, WAL enabled,
`--wal-fsync=true`, health checks, and regular `dump_all` or `SIGUSR1`
snapshots.

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

Basic production-oriented run:

```sh
bin/karma \
  --bind=0.0.0.0 \
  --port=8080 \
  --directory=/var/lib/karma \
  --restore=true \
  --wal=true \
  --wal-fsync=true
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

Options:

```text
-b host, --bind=host
  Host to bind. Default: 0.0.0.0

-p port, --port=port
  Port to listen on. Default: 8080

-d path, --directory=path
  Directory for snapshots and WAL. Default: .

-r flag, --restore=flag
  Load snapshots and replay WAL on startup. Default: true

-n flag, --nodelay=flag
  Enable TCP_NODELAY on the server socket. Default: true

-w flag, --wal=flag
  Enable write-ahead log for mutating commands. Default: true

--wal-fsync=flag
  Fsync every WAL append and WAL truncate. Default: true

--max-request-bytes=bytes
  Maximum JSON request line size. Default: 4096

--max-response-bytes=bytes
  Maximum JSON response size. Use 0 to disable the limit. Default: 1048576

--read-timeout=seconds
  Client socket read timeout. Default: 5

--write-timeout=seconds
  Client socket write timeout. Default: 5

--query-timeout-ms=ms
  Tree-level read timeout in milliseconds. Use 0 to disable the limit.
  Default: 1000

--shutdown-timeout=seconds
  Seconds to wait for active clients on shutdown before closing remaining
  sockets. Default: 5

--auth-token=token
  Require every client command to include the same token field.

--read-auth-token=token
  Allow the token field to authorize read-only commands only.

--dump-retention-per-tree=count
  Number of snapshots to keep per tree after dump_all. Default: 5

--log=flag
  Emit structured JSON logs to stdout/stderr. Default: true
```

Boolean flags use `true` or `false`.
Numeric timeout values use `0` to disable the corresponding timeout. The
request byte limit must be greater than `0`; the response byte limit may be `0`
to disable the response limit.

Environment variables:

```text
KARMA_HOST
  Same as --bind.

KARMA_PORT
  Same as --port.

KARMA_DUMP_DIR
  Same as --directory.

KARMA_RESTORE
  Same as --restore.

KARMA_TCP_NODELAY
  Same as --nodelay.

KARMA_WAL
  Same as --wal.

KARMA_WAL_FSYNC
  Same as --wal-fsync.

KARMA_MAX_REQUEST_BYTES
  Same as --max-request-bytes.

KARMA_MAX_RESPONSE_BYTES
  Same as --max-response-bytes.

KARMA_READ_TIMEOUT_SECONDS
  Same as --read-timeout.

KARMA_WRITE_TIMEOUT_SECONDS
  Same as --write-timeout.

KARMA_QUERY_TIMEOUT_MS
  Same as --query-timeout-ms.

KARMA_SHUTDOWN_TIMEOUT_SECONDS
  Same as --shutdown-timeout.

KARMA_AUTH_TOKEN
  Same as --auth-token. Empty value disables the token.

KARMA_READ_AUTH_TOKEN
  Same as --read-auth-token. Empty value disables the token.

KARMA_DUMP_RETENTION_PER_TREE
  Same as --dump-retention-per-tree.

KARMA_LOG
  Same as --log.
```

Boolean environment variables also use `true` or `false`.

## Protocol

Karma speaks newline-delimited JSON over TCP. Each request is one JSON object
followed by `\n`. Each response is one JSON object followed by `\r\n`.

Protocol v2 is the preferred protocol for new clients. Requests use a stable
`v: 2` envelope, namespaced `op` values, and time-series terminology:

```json
{"v":2,"op":"counter.increment","series":"links","key":42,"bucket":20260505,"value":1}
```

The older v1 protocol remains supported for compatibility and WAL replay. v1
requests use `command`, `tree_name`, `date`, and `time_from`/`time_to`. v1 usage
is counted in `stats.legacy_request_count` and
`karma_protocol_v1_requests_total`.

Response schema:

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
* `internal_error`

If `--auth-token` is configured, include `token` in every client request:

```json
{"v":2,"op":"system.ping","token":"secret"}
```

If `--read-auth-token` is configured, that token can execute read-only
commands such as `system.ping`, `tree.list`, `counter.sum`,
`counter.batch_sum`, `counter.series`, `system.stats`, `system.metrics`,
`tree.info`, `tree.keys`, `tree.summary`, `tree.top`, and `snapshot.info`.
Mutating or admin commands return `forbidden` for a read-only token.

Tokens are not written to WAL.

## Data Model

* A series is a named collection of counters. The storage layer and legacy API
  still use the word tree.
* A key is an unsigned 64-bit integer inside a series.
* A bucket is a day in `YYYYMMDD` format, for example `20260504`.
* Default buckets use UTC days.
* Counter values are unsigned 64-bit integers and never go below zero.
* `counter.increment` and `counter.decrement` use today's bucket when `bucket`
  is omitted.

Read commands do not create missing series. Missing series return `not_found`.
For existing series, reading a missing key returns empty or zero values.

## v2 Commands

### ping

Check that the server responds.

Request:

```json
{"v":2,"op":"system.ping"}
```

Response:

```json
{"protocol_version":2,"success":true,"response":"pong","error_code":null}
```

### tree.create

Create a series if it does not already exist.

```json
{"v":2,"op":"tree.create","series":"links"}
```

Response:

```json
{"protocol_version":2,"success":true,"response":"OK","error_code":null}
```

### tree.drop

Delete a series from memory.

```json
{"v":2,"op":"tree.drop","series":"links"}
```

### tree.list

List series names.

```json
{"v":2,"op":"tree.list"}
```

### counter.increment

Increment a key for a bucket. If `bucket` is omitted, Karma uses today's UTC
day.

```json
{"v":2,"op":"counter.increment","series":"links","key":42,"bucket":20260505,"value":1}
```

Response `response` is the increment amount:

```json
{"protocol_version":2,"success":true,"response":1,"error_code":null}
```

### counter.decrement

Decrement a key for a bucket. The counter never goes below zero.

```json
{"v":2,"op":"counter.decrement","series":"links","key":42,"bucket":20260505,"value":1}
```

### counter.sum

Read total for a key:

```json
{"v":2,"op":"counter.sum","series":"links","key":42}
```

Read total for a date range:

```json
{
  "v": 2,
  "op": "counter.sum",
  "series": "links",
  "key": 42,
  "range": {"from": 20260501, "to": 20260504}
}
```

### counter.batch_sum

Read totals for many keys in one request:

```json
{"v":2,"op":"counter.batch_sum","series":"links","keys":[41,42,43]}
```

With a range:

```json
{
  "v": 2,
  "op": "counter.batch_sum",
  "series": "links",
  "keys": [41, 42, 43],
  "range": {"from": 20260501, "to": 20260504}
}
```

### counter.series

Read daily values for one key:

```json
{
  "v": 2,
  "op": "counter.series",
  "series": "links",
  "key": 42,
  "range": {"from": 20260501, "to": 20260504}
}
```

### series.batch_add

Add many `[key, bucket, value]` items in one request:

```json
{
  "v": 2,
  "op": "series.batch_add",
  "series": "links",
  "items": [[42, 20260505, 10], [43, 20260505, 3]]
}
```

Large batches must fit `--max-request-bytes`; increase it for backfill or
streaming ingest clients.

### tree.series

Read daily values for all keys in a series:

```json
{
  "v": 2,
  "op": "tree.series",
  "series": "links",
  "range": {"from": 20260501, "to": 20260504}
}
```

### tree.summary

Return key count, bucket count, and total sum for a series:

```json
{"v":2,"op":"tree.summary","series":"links"}
```

With a range:

```json
{"v":2,"op":"tree.summary","series":"links","range":{"from":20260501,"to":20260504}}
```

### tree.top

Return top keys by total value:

```json
{"v":2,"op":"tree.top","series":"links","limit":100}
```

### tree.keys

Return keys with cursor pagination:

```json
{"v":2,"op":"tree.keys","series":"links","limit":1000,"cursor":0}
```

### delete and reset

Delete date-range values for one key:

```json
{"v":2,"op":"counter.delete_range","series":"links","key":42,"range":{"from":20260501,"to":20260504}}
```

Delete date-range values for all keys in a series:

```json
{"v":2,"op":"tree.delete_range","series":"links","range":{"from":20260501,"to":20260504}}
```

Delete old buckets:

```json
{"v":2,"op":"series.delete_before","series":"links","before":20260401}
```

Reset one key or a whole series:

```json
{"v":2,"op":"counter.reset","series":"links","key":42}
{"v":2,"op":"tree.reset","series":"links"}
```

### ingest

Streaming ingest loads large batches as ordered chunks. Supported modes are:

* `add`: add item values to the live series;
* `set`: set item bucket values in the live series;
* `replace_series`: build a staged series and atomically replace the live
  series on `ingest.commit`.

Duplicate chunks are skipped and out-of-order chunks are rejected before they
are applied. One stream is bound to the series used by its first chunk.

```json
{"v":2,"op":"ingest.begin","stream_id":"import-20260505","mode":"add","granularity":"day"}
{"v":2,"op":"ingest.chunk","stream_id":"import-20260505","series":"links","chunk_seq":1,"items":[[42,20260505,10]]}
{"v":2,"op":"ingest.commit","stream_id":"import-20260505"}
```

`replace_series` keeps current reads pointed at the old series until commit:

```json
{"v":2,"op":"ingest.begin","stream_id":"rebuild-links","mode":"replace_series","granularity":"day"}
{"v":2,"op":"ingest.chunk","stream_id":"rebuild-links","series":"links","chunk_seq":1,"items":[[42,20260505,10]]}
{"v":2,"op":"ingest.commit","stream_id":"rebuild-links"}
```

Abort an active stream:

```json
{"v":2,"op":"ingest.abort","stream_id":"import-20260505"}
```

### snapshots

Create, list, load, verify, and inspect snapshots:

```json
{"v":2,"op":"snapshot.create","series":"links"}
{"v":2,"op":"snapshot.create_all"}
{"v":2,"op":"snapshot.list"}
{"v":2,"op":"snapshot.load","file":"1777925811_links.tree"}
{"v":2,"op":"snapshot.verify"}
{"v":2,"op":"snapshot.info"}
```

### system

Runtime and operational commands:

```json
{"v":2,"op":"system.health"}
{"v":2,"op":"system.stats"}
{"v":2,"op":"system.metrics"}
{"v":2,"op":"system.compact"}
```

Report reconciliation results from external checks:

```json
{"v":2,"op":"reconciliation.report","checked_points":1000,"mismatch_count":2,"absolute_drift":15,"max_abs_delta":10}
```

Record and inspect recovery checkpoints for external ingestion sources:

```json
{"v":2,"op":"recovery.checkpoint","source":"clickhouse-links","offset":"export-2026-05-05","event_id":"batch-42"}
{"v":2,"op":"recovery.status"}
{"v":2,"op":"recovery.status","source":"clickhouse-links"}
```

### Legacy v1

Legacy clients can continue to use v1 `command` requests:

```json
{"command":"increment","tree_name":"links","key":42}
{"command":"sum","tree_name":"links","key":42}
```

These requests return `protocol_version: 1`. New clients should use v2.

## Metrics

Metrics include:

* `karma_uptime_seconds`
* `karma_trees`
* `karma_keys`
* `karma_dumps`
* `karma_wal_bytes`
* `karma_wal_current_lsn`
* `karma_memory_bytes`
* `karma_commands_total`
* `karma_errors_total`
* `karma_protocol_v1_requests_total`
* `karma_query_timeouts_total`
* `karma_batch_reads_total`
* `karma_batch_read_keys_total`
* `karma_batch_writes_total`
* `karma_batch_write_items_total`
* `karma_retention_operations_total`
* `karma_compactions_total`
* `karma_reconciliation_runs_total`
* `karma_reconciliation_checked_points_total`
* `karma_reconciliation_mismatches_total`
* `karma_reconciliation_absolute_drift_total`
* `karma_reconciliation_last_run_unix`
* `karma_reconciliation_last_checked_points`
* `karma_reconciliation_last_mismatches`
* `karma_reconciliation_last_absolute_drift`
* `karma_reconciliation_last_max_abs_delta`
* `karma_recovery_checkpoints`
* `karma_recovery_last_checkpoint_unix`
* `karma_command_latency_ms`
* `karma_command_latency_ms_average`
* `karma_ingest_active_streams`
* `karma_ingest_chunks_applied_total`
* `karma_ingest_chunks_skipped_total`
* `karma_ingest_chunks_rejected_total`
* `karma_ingest_items_applied_total`
* `karma_ingest_chunk_latency_ms`
* `karma_ingest_chunk_latency_ms_average`

## Examples

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

## Persistence

Karma uses two persistence mechanisms:

* snapshots: MessagePack `.tree` files, one per tree;
* WAL: newline-delimited JSON entries in `karma.wal`.

New WAL lines use an LSN envelope:

```json
{"v":2,"lsn":1,"entry":{"v":2,"op":"counter.increment","tree":"links","key":42,"date":20260505,"value":1}}
```

The current WAL LSN is persisted in `karma.wal.lsn`. WAL replay accepts both
the LSN envelope and older WAL lines where the command JSON is written directly
at the top level.

Recovery checkpoint metadata is stored separately in `recovery.json` in the
same directory. It records external source positions such as ClickHouse export
ids or durable queue offsets. It is loaded on startup before serving commands.

Startup with `--restore=true`:

1. Load the latest snapshot per tree.
2. Replay WAL entries.

`snapshot.create_all` / legacy `dump_all`:

1. Writes atomic snapshots through a temporary file and rename.
2. Fsyncs snapshot files before rename.
3. Truncates WAL after successful snapshotting.
4. Prunes old snapshots per tree.

## Signals

* `SIGINT`: stop accepting new TCP clients, dump all trees, truncate WAL after
  successful snapshots, and exit with status 0.
* `SIGUSR1`: dump all trees, truncate WAL after successful snapshots, and keep
  running.

## Performance

Local test results on this development machine:

* native binary, WAL enabled, `--wal-fsync=false`: about 25k writes/sec;
* native binary, WAL enabled, `--wal-fsync=true`: about 19k writes/sec;
* Docker with bind mount and `--wal-fsync=true`: about 5k writes/sec.

Actual production throughput depends on CPU, disk, filesystem, container
runtime, network, and workload mix.

Run the in-process command-layer load test:

```sh
crystal build --release scripts/load_test.cr -o bin/karma_load_test
bin/karma_load_test
```

Smaller smoke run:

```sh
crystal run scripts/load_test.cr -- \
  --keys=1000 \
  --batch-size=100 \
  --single-rounds=1000 \
  --read-rounds=10
```

Run the TCP load test against a real loopback Karma server:

```sh
crystal build --release scripts/tcp_load_test.cr -o bin/karma_tcp_load_test
bin/karma_tcp_load_test \
  --clients=4 \
  --wal=true \
  --wal-fsync=false
```

For the conservative WAL path, use `--wal-fsync=true`.

Run CSV reconciliation against ClickHouse/exported aggregates:

```sh
crystal run scripts/reconcile_csv.cr -- \
  --host=127.0.0.1 \
  --port=8080 \
  --series=links \
  --csv=clickhouse-links.csv \
  --report
```

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

The `counter_tree` library is vendored in `lib/counter_tree` so counter storage
changes can be developed and tested inside this repository.

## Clients

Karma's protocol is simple JSON over TCP. Existing higher-level clients may need
updates to emit v2 request envelopes, handle protocol version `2` responses,
send auth tokens, and use the newer operational commands.

## License

MIT
