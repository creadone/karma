<p align="center">
  <img src="https://raw.githubusercontent.com/creadone/karma/master/docs/karma.png" height="200">
  <h3 align="center">Karma</h3>
</p>

Karma is a small TCP database for positive counters with one-day granularity.
It stores named groups of counters called trees. Each tree contains many
numeric keys, and each key stores daily values plus a total.

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

--read-timeout=seconds
  Client socket read timeout. Default: 5

--write-timeout=seconds
  Client socket write timeout. Default: 5

--auth-token=token
  Require every client command to include the same token field.

--dump-retention-per-tree=count
  Number of snapshots to keep per tree after dump_all. Default: 5

--log=flag
  Emit structured JSON logs to stdout/stderr. Default: true
```

Boolean flags use `true` or `false`.

## Protocol

Karma speaks newline-delimited JSON over TCP. Each request is one JSON object
followed by `\n`. Each response is one JSON object followed by `\r\n`.

Response schema:

```json
{
  "protocol_version": 1,
  "success": true,
  "response": "OK",
  "error_code": null
}
```

Error response:

```json
{
  "protocol_version": 1,
  "success": false,
  "response": "Field tree_name is required",
  "error_code": "validation_error"
}
```

Stable error codes:

* `invalid_json`
* `unknown_command`
* `validation_error`
* `not_found`
* `unauthorized`
* `request_too_large`
* `internal_error`

If `--auth-token` is configured, include `token` in every client request:

```json
{"command":"ping","token":"secret"}
```

Tokens are not written to WAL.

## Data Model

* A tree is a named collection of counters.
* A key is an unsigned 64-bit integer inside a tree.
* `increment` and `decrement` operate on the current local day.
* Dates are unsigned integers in `YYYYMMDD` format, for example `20260504`.
* Counter values are unsigned 64-bit integers and never go below zero.

Read commands do not create missing trees. Missing trees return `not_found`.
For existing trees, reading a missing key returns empty or zero values.

## Commands

### ping

Check that the server responds.

Request:

```json
{"command":"ping"}
```

Response:

```json
{"protocol_version":1,"success":true,"response":"pong","error_code":null}
```

### create

Create a tree if it does not already exist.

```json
{"command":"create","tree_name":"links"}
```

Response:

```json
{"protocol_version":1,"success":true,"response":"OK","error_code":null}
```

### drop

Delete a tree from memory.

```json
{"command":"drop","tree_name":"links"}
```

### trees

List tree names.

```json
{"command":"trees"}
```

### increment

Increment a key for the current day by `1`.

```json
{"command":"increment","tree_name":"links","key":42}
```

Response `response` is the increment amount:

```json
{"protocol_version":1,"success":true,"response":1,"error_code":null}
```

### decrement

Decrement a key for the current day by `1`.

```json
{"command":"decrement","tree_name":"links","key":42}
```

The counter never goes below zero.

### sum

Read total for a key:

```json
{"command":"sum","tree_name":"links","key":42}
```

Read total for a date range:

```json
{
  "command": "sum",
  "tree_name": "links",
  "key": 42,
  "time_from": 20260501,
  "time_to": 20260504
}
```

### find

Read daily values for one key:

```json
{
  "command": "find",
  "tree_name": "links",
  "key": 42,
  "time_from": 20260501,
  "time_to": 20260504
}
```

Read daily values for all keys in a tree:

```json
{
  "command": "find",
  "tree_name": "links",
  "time_from": 20260501,
  "time_to": 20260504
}
```

### delete

Delete date-range values for one key:

```json
{
  "command": "delete",
  "tree_name": "links",
  "key": 42,
  "time_from": 20260501,
  "time_to": 20260504
}
```

Delete date-range values for all keys in a tree:

```json
{
  "command": "delete",
  "tree_name": "links",
  "time_from": 20260501,
  "time_to": 20260504
}
```

### reset

Reset one key:

```json
{"command":"reset","tree_name":"links","key":42}
```

Reset all keys in a tree:

```json
{"command":"reset","tree_name":"links"}
```

### dump

Write one tree snapshot to the configured directory.

```json
{"command":"dump","tree_name":"links"}
```

### dump_all

Write snapshots for all trees, truncate WAL after successful snapshotting, and
prune old snapshots according to `--dump-retention-per-tree`.

```json
{"command":"dump_all"}
```

### dumps

List known snapshot files, newest first.

```json
{"command":"dumps"}
```

### load

Load one snapshot file from the configured directory. The file name is passed in
`tree_name` for backwards compatibility.

```json
{"command":"load","tree_name":"1777925811_links.tree"}
```

### health

Return service health and uptime.

```json
{"command":"health"}
```

### stats

Return runtime stats: uptime, tree count, key count, dump count, WAL state, heap
size, command count, error count, and command latency.

```json
{"command":"stats"}
```

### metrics

Return Prometheus-style metrics text.

```json
{"command":"metrics"}
```

Metrics include:

* `karma_uptime_seconds`
* `karma_trees`
* `karma_keys`
* `karma_dumps`
* `karma_wal_bytes`
* `karma_memory_bytes`
* `karma_commands_total`
* `karma_errors_total`
* `karma_command_latency_ms`
* `karma_command_latency_ms_average`

### verify

Verify that snapshots and WAL can be restored.

```json
{"command":"verify"}
```

## Examples

Using `nc`:

```sh
printf '{"command":"increment","tree_name":"links","key":42}\n' | nc 127.0.0.1 8080
printf '{"command":"sum","tree_name":"links","key":42}\n' | nc 127.0.0.1 8080
```

Using Crystal:

```crystal
require "json"
require "socket"

socket = TCPSocket.new("127.0.0.1", 8080)
socket << {command: "increment", tree_name: "links", key: 42_u64}.to_json << "\n"
puts socket.gets
socket.close
```

Using Ruby:

```ruby
require "json"
require "socket"

socket = TCPSocket.new("127.0.0.1", 8080)
socket.write({command: "sum", tree_name: "links", key: 42}.to_json + "\n")
puts socket.gets
socket.close
```

## Persistence

Karma uses two persistence mechanisms:

* snapshots: MessagePack `.tree` files, one per tree;
* WAL: newline-delimited JSON commands in `karma.wal`.

Startup with `--restore=true`:

1. Load the latest snapshot per tree.
2. Replay WAL entries.

`dump_all`:

1. Writes atomic snapshots through a temporary file and rename.
2. Fsyncs snapshot files before rename.
3. Truncates WAL after successful snapshotting.
4. Prunes old snapshots per tree.

## Signals

* `SIGINT`: dump all trees and exit.
* `SIGUSR1`: dump all trees and keep running.

## Performance

Local test results on this development machine:

* native binary, WAL enabled, `--wal-fsync=false`: about 25k writes/sec;
* native binary, WAL enabled, `--wal-fsync=true`: about 19k writes/sec;
* Docker with bind mount and `--wal-fsync=true`: about 5k writes/sec.

Actual production throughput depends on CPU, disk, filesystem, container
runtime, network, and workload mix.

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
updates to support protocol version `1` responses, auth tokens, and operational
commands.

## License

MIT
