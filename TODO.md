# TODO

No open items for the 1.0 plan.

Completed:

* v2-only protocol enforcement for client requests and WAL replay.
* Single-parse command dispatch for v2 payloads.
* Fast paths for simple `counter.sum` and `counter.increment`.
* Per-series coordination for hot point operations.
* Specialized UInt64 responses for point reads/writes.
* Synchronous WAL writer batching and flush-ack increment batching.
