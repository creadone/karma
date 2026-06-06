# AGENTS.md

Read this file before changing Karma as a coding agent. The full developer
guide is `docs/development.ru.md`; this file is a short operational checklist.

## Project Context

Karma is a TCP service for fast day-bucketed limit usage accounting. The main
use case is: an application writes usage and reads a fresh total by limit,
subject, and UTC day. Other counter use cases are not primary when choosing
names, APIs, or optimizations.

Use limit-usage language in public documentation and clients: `series` is the
limit name, `key` is the subject id, `bucket` is the UTC day, and `value` is
the usage amount.

## Invariants

* Karma 1.0 accepts protocol v2 only: requests must include `"v": 2` and `op`.
* Do not bring back legacy/v1 support.
* Do not write to `Cluster` before a successful WAL write for a persisted
  mutation when WAL is enabled.
* Do not bypass the `slave` role check for writes.
* Keep stable `error_code` values; add a new code only for a genuinely new
  error category.
* Check `UInt64` overflow before mutating counters.
* The internal data structure is `Karma::BucketedCounter::Store`. Historical
  `tree` naming remains only in the external v2 protocol, metrics, and `.tree`
  snapshot files.

## Before Changes

* Read the relevant files in `src/`, `spec/`, and documentation first.
* For a new or changed `op`, update the parser, handler, registry, validator,
  specs, and README in the same change.
* For WAL, snapshot, replication, or idempotency changes, check the relevant
  specs and documentation.
* For client changes, update the client README and client tests.

## Checks

Baseline:

```sh
crystal spec
shards build --release
```

Focused suites:

```sh
crystal spec spec/command_spec.cr
crystal spec spec/wal_spec.cr
crystal spec spec/replication_spec.cr
crystal spec spec/idempotency_spec.cr
crystal spec spec/bucketed_counter
crystal spec clients/crystal/spec
ruby clients/ruby/test/karma_client_test.rb
```

Before committing, make sure `git diff --check` is clean. Do not commit
`.crystal-cache-*`, `.karma-data`, `.spec_*`, `bin/`, snapshots, WAL files, or
temporary files.

## Documentation

When public behavior changes, update:

* `README.md`;
* `README.ru.md`;
* `docs/development.ru.md`;
* client READMEs when client APIs change.

Documentation must not present unsupported scenarios as first-class use cases.
For Karma 1.0, the primary scenario is limit usage accounting.
