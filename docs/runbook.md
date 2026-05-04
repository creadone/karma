# Karma Production Runbook

## Start

```sh
karma --bind=0.0.0.0 --port=8080 --directory=/data --restore=true --wal=true --wal-fsync=true
```

Recommended production flags:

- `--directory`: persistent volume for `.tree` snapshots and `karma.wal`.
- `--wal=true`: keeps writes durable between snapshots.
- `--wal-fsync=true`: fsyncs each WAL append for stronger crash safety.
- `--auth-token`: require clients to include `token` in commands.
- `--max-request-bytes`: caps one JSON request line.
- `--dump-retention-per-tree`: keeps recent snapshots per tree after `dump_all`.

## Health

Send:

```json
{"command":"health"}
```

Expected response:

```json
{"protocol_version":1,"success":true,"response":{"status":"ok"},"error_code":null}
```

## Stats

Send:

```json
{"command":"stats"}
```

The response includes uptime, tree count, key count, dump count, WAL size and
heap size.

## Metrics

Send:

```json
{"command":"metrics"}
```

The response is a Prometheus-style text payload with uptime, trees, keys, dumps,
WAL bytes, heap size, command/error counters and command latency gauges.

## Backup

Create snapshots:

```json
{"command":"dump_all"}
```

Verify restore path:

```json
{"command":"verify"}
```

`dump_all` writes atomic `.tree` snapshots, truncates WAL after successful
snapshotting, and prunes old dumps according to `--dump-retention-per-tree`.

## Restore

On startup with `--restore=true`, Karma loads the latest snapshot per tree and
then replays `karma.wal`.

## Failure Response

Errors include stable codes:

- `invalid_json`
- `unknown_command`
- `validation_error`
- `not_found`
- `unauthorized`
- `request_too_large`
- `internal_error`
