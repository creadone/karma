# TODO

## Speed up point reads and writes

Focus on `counter.sum` and `counter.increment`, where the tree operation itself is
already cheap and most latency comes from the command pipeline around it.

1. Parse JSON once in `Commands.call`.
   The current hot path parses once to detect protocol version and then parses
   the same request again for dispatch. Reuse the parsed object.

2. Add a v2 fast path for simple `counter.sum` and `counter.increment`.
   Handle payloads without `token`, `idempotency_key`, range, or legacy fields
   directly, with fallback to the full `Directive` pipeline for all other cases.

3. Replace the global state mutex for hot point operations.
   Evaluate per-series or sharded per-key locking so concurrent reads and writes
   to independent keys do not queue behind one global lock. Snapshot, compact,
   drop, and restore still need wider coordination.

4. Add specialized UInt64 success responses for point operations.
   Avoid the fully generic response builder for the most frequent scalar results.

Measure in-process and TCP `single_sum`/`single_increment` with WAL off and with
WAL on + fsync off, including p50/p95 latency and correctness under concurrent
clients.

## Check single-increment micro-batching

Evaluate a server-side in-memory buffer for high-volume single `counter.increment`
requests.

Compare:

* current strict single increment path;
* `flush_ack` micro-batching: acknowledge only after batch apply + WAL append;
* optional `async_ack`: acknowledge after enqueue, if weaker durability is acceptable.

Measure throughput, p50/p95 latency, WAL pressure, replication lag, shutdown drain,
read-after-write behavior, and idempotency interactions.

Initial target for `flush_ack`: reach about `100k+` single increments/sec without
weakening the current success-is-durable contract.

Also evaluate a dedicated WAL writer with batch writes/group commit:

* for `wal_fsync=false`, flush accepted entries in small batches by count/time;
* for `wal_fsync=true`, group fsync multiple accepted mutations together;
* preserve ordering, replication LSN monotonicity, shutdown drain, and the
  current success-is-durable contract for `flush_ack`.
