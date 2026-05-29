# TODO

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
