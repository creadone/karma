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
- `--dump-retention-per-tree`: keeps recent snapshots per series after
  `snapshot.create_all`.

Karma 1.0 accepts protocol v2 only. Every request is one JSON object followed
by `\n`; every response is a v2 envelope followed by `\r\n`.

## Health

Send:

```json
{"v":2,"op":"system.health"}
```

Expected response:

```json
{"protocol_version":2,"success":true,"response":{"status":"ok","uptime_seconds":1.0,"role":"master","wal_enabled":true},"error_code":null}
```

## Stats

Send:

```json
{"v":2,"op":"system.stats"}
```

The response includes uptime, role, series/tree count, key count, snapshot
count, WAL size and LSN, memory size, command counters, ingest counters,
idempotency counters, recovery counters, and replication status.

## Metrics

Send:

```json
{"v":2,"op":"system.metrics"}
```

The response is a Prometheus-style text payload with uptime, role, series/key
counts, snapshots, WAL bytes and LSN, memory size, command/error counters,
latency gauges, ingest, idempotency, recovery, reconciliation, and replication
metrics.

## Backup

Create snapshots:

```json
{"v":2,"op":"snapshot.create_all"}
```

Verify restore path:

```json
{"v":2,"op":"snapshot.verify"}
```

`snapshot.create_all` writes atomic `.tree` snapshots, truncates WAL after
successful snapshotting, and prunes old snapshots according to
`--dump-retention-per-tree`.

## Restore

On startup with `--restore=true`, Karma loads the latest snapshot per series and
then replays `karma.wal`.

## Failure Response

Errors include stable codes:

- `invalid_json`
- `unsupported_protocol`
- `unknown_command`
- `validation_error`
- `not_found`
- `unauthorized`
- `forbidden`
- `request_too_large`
- `response_too_large`
- `query_timeout`
- `idempotency_conflict`
- `replication_gap`
- `replication_error`
- `internal_error`
