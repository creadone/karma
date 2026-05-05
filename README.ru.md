<p align="center">
  <img src="https://raw.githubusercontent.com/creadone/karma/master/docs/karma.png" height="200">
  <h3 align="center">Karma</h3>
</p>

Karma - небольшая TCP-база данных для горячих time-series счетчиков. Она нужна
там, где приложению важно быстро получать свежие агрегированные счетчики и не
дергать тяжелое аналитическое хранилище на каждый пользовательский запрос.

Типичный сценарий:

```text
приложение читает metadata ссылок
  -> приложение запрашивает в Karma счетчики для набора link id
  -> клиент получает список ссылок со свежими счетчиками кликов
```

Karma хранит данные в памяти, сохраняет их через snapshots и WAL, а наружу
отдает простой newline-delimited JSON protocol поверх TCP.

English version: [README.md](README.md).

## Статус

Karma сейчас лучше рассматривать как production-oriented hot counter read model,
а не как универсальную TSDB.

Что уже поддерживается:

* счетчики по дневным bucket-ам в формате `YYYYMMDD`;
* одиночные чтения и записи;
* batch reads и batch writes;
* streaming ingest для rebuild/backfill;
* атомарные snapshots и WAL replay;
* recovery checkpoints и отчеты reconciliation;
* асинхронная master -> slave репликация через snapshot bootstrap и WAL polling;
* Prometheus-style operational metrics.

Важные границы текущей версии:

* выполнение команд сериализовано одним process-local lock;
* репликация асинхронная, failover только ручной;
* automatic leader election, quorum и master-master режима нет;
* object-storage transport для snapshots и `replication.subscribe` пока не
  реализованы.

Для production запускайте Karma на persistent volume, с включенным WAL,
`--wal-fsync=true`, health checks, сбором metrics и регулярными
`snapshot.create_all` или `SIGUSR1` snapshots.

## Сборка

Требования:

* Crystal 1.17.1
* Shards

Сборка:

```sh
shards build --release
```

Бинарь будет создан здесь:

```sh
bin/karma
```

## Docker

Собрать image:

```sh
docker build -t karma:local .
```

Запустить:

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

## Запуск

Рекомендуемый запуск master node:

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

Ту же конфигурацию можно задать переменными окружения. CLI options применяются
после env vars и переопределяют их:

```sh
KARMA_HOST=0.0.0.0 \
KARMA_PORT=8080 \
KARMA_DUMP_DIR=/var/lib/karma \
KARMA_RESTORE=true \
KARMA_WAL=true \
KARMA_WAL_FSYNC=true \
bin/karma
```

## Конфигурация

Boolean значения задаются как `true` или `false`. Timeout-ы указываются в
секундах, кроме опций, где явно написано `-ms`.

| CLI option | Env var | Default | Описание |
| --- | --- | ---: | --- |
| `--bind=host` | `KARMA_HOST` | `0.0.0.0` | Host, на котором слушает сервер. |
| `--port=port` | `KARMA_PORT` | `8080` | TCP port. |
| `--directory=path` | `KARMA_DUMP_DIR` | `.` | Директория для snapshots, WAL и metadata. |
| `--role=master\|slave` | `KARMA_ROLE` | `master` | Роль node. |
| `--restore=true\|false` | `KARMA_RESTORE` | `true` | Загружать snapshots и replay-ить WAL при старте. |
| `--nodelay=true\|false` | `KARMA_TCP_NODELAY` | `true` | Включить TCP_NODELAY. |
| `--wal=true\|false` | `KARMA_WAL` | `true` | Писать mutating commands в WAL. |
| `--wal-fsync=true\|false` | `KARMA_WAL_FSYNC` | `true` | Делать fsync на каждый WAL append/truncate. |
| `--max-request-bytes=bytes` | `KARMA_MAX_REQUEST_BYTES` | `4096` | Максимальный размер JSON request line. Должен быть больше 0. |
| `--max-response-bytes=bytes` | `KARMA_MAX_RESPONSE_BYTES` | `1048576` | Максимальный размер JSON response. `0` отключает лимит. |
| `--read-timeout=seconds` | `KARMA_READ_TIMEOUT_SECONDS` | `5` | Socket read timeout. `0` отключает. |
| `--write-timeout=seconds` | `KARMA_WRITE_TIMEOUT_SECONDS` | `5` | Socket write timeout. `0` отключает. |
| `--query-timeout-ms=ms` | `KARMA_QUERY_TIMEOUT_MS` | `1000` | Timeout для дорогих tree-level reads. `0` отключает. |
| `--shutdown-timeout=seconds` | `KARMA_SHUTDOWN_TIMEOUT_SECONDS` | `5` | Сколько ждать active clients при graceful shutdown. |
| `--auth-token=token` | `KARMA_AUTH_TOKEN` | unset | Token, обязательный для всех команд. Пустой env value отключает. |
| `--read-auth-token=token` | `KARMA_READ_AUTH_TOKEN` | unset | Token только для read-only commands. Пустой env value отключает. |
| `--dump-retention-per-tree=count` | `KARMA_DUMP_RETENTION_PER_TREE` | `5` | Сколько snapshots хранить на series после `snapshot.create_all`. |
| `--replication-source-host=host` | `KARMA_REPLICATION_SOURCE_HOST` | unset | Master host для slave polling. |
| `--replication-source-port=port` | `KARMA_REPLICATION_SOURCE_PORT` | `8080` | Master port для slave polling. |
| `--replication-token=token` | `KARMA_REPLICATION_TOKEN` | unset | Token для replication requests со slave. |
| `--replication-poll-interval-ms=ms` | `KARMA_REPLICATION_POLL_INTERVAL_MS` | `1000` | Интервал polling на slave. |
| `--replication-batch-size=count` | `KARMA_REPLICATION_BATCH_SIZE` | `1000` | Максимум WAL entries за один slave poll. Max: 10000. |
| `--log=true\|false` | `KARMA_LOG` | `true` | Писать structured JSON logs. |

## Протокол

Karma говорит newline-delimited JSON поверх TCP:

* один request - один JSON object и `\n`;
* один response - один JSON object и `\r\n`.

Для новых клиентов предпочтителен protocol v2. В нем есть `v: 2`,
namespaced `op` и терминология `series/key/bucket/value`:

```json
{"v":2,"op":"counter.increment","series":"links","key":42,"bucket":20260505,"value":1}
```

Legacy v1 protocol остается для compatibility и WAL replay. Legacy requests
используют `command`, `tree_name`, `date`, `time_from`/`time_to`. Новым
клиентам лучше использовать v2.

Успешный response:

```json
{
  "protocol_version": 2,
  "success": true,
  "response": "OK",
  "error_code": null
}
```

Ошибка:

```json
{
  "protocol_version": 2,
  "success": false,
  "response": "Field tree or series is required",
  "error_code": "validation_error"
}
```

Стабильные error codes:

* `invalid_json`
* `unknown_command`
* `validation_error`
* `not_found`
* `unauthorized`
* `forbidden`
* `request_too_large`
* `response_too_large`
* `query_timeout`
* `replication_gap`
* `replication_error`
* `internal_error`

Если настроен `--auth-token`, добавляйте `token` в каждый client request. Если
настроен `--read-auth-token`, этот token может выполнять только read-only
commands. Tokens не пишутся в WAL.

## Модель данных

* **series** - именованная коллекция счетчиков. Storage layer и legacy API еще
  используют слово `tree`.
* **key** - unsigned 64-bit integer внутри series.
* **bucket** - UTC-день в формате `YYYYMMDD`, например `20260505`.
* **value** - unsigned 64-bit integer.
* Increment/decrement используют сегодняшний UTC bucket, если `bucket` не задан.
* Значения счетчиков никогда не уходят ниже нуля.

Read commands не создают missing series. Missing series возвращает `not_found`.
Для существующей series missing key возвращает ноль или пустой результат.

## Примеры команд

### Базовые счетчики

Создать series:

```json
{"v":2,"op":"tree.create","series":"links"}
```

Увеличить счетчик за сегодня:

```json
{"v":2,"op":"counter.increment","series":"links","key":42,"value":1}
```

Увеличить счетчик в конкретном bucket:

```json
{"v":2,"op":"counter.increment","series":"links","key":42,"bucket":20260505,"value":1}
```

Уменьшить счетчик:

```json
{"v":2,"op":"counter.decrement","series":"links","key":42,"bucket":20260505,"value":1}
```

Прочитать total по key:

```json
{"v":2,"op":"counter.sum","series":"links","key":42}
```

Прочитать range:

```json
{"v":2,"op":"counter.sum","series":"links","key":42,"range":{"from":20260501,"to":20260505}}
```

Прочитать daily points:

```json
{"v":2,"op":"counter.series","series":"links","key":42,"range":{"from":20260501,"to":20260505}}
```

### Batch чтение и запись

Прочитать много totals одним request:

```json
{"v":2,"op":"counter.batch_sum","series":"links","keys":[41,42,43]}
```

Прочитать много totals за range:

```json
{"v":2,"op":"counter.batch_sum","series":"links","keys":[41,42,43],"range":{"from":20260501,"to":20260505}}
```

Добавить много `[key, bucket, value]` items:

```json
{"v":2,"op":"series.batch_add","series":"links","items":[[42,20260505,10],[43,20260505,3]]}
```

Большие batch requests должны помещаться в `--max-request-bytes`.

### Инспекция series

Список series:

```json
{"v":2,"op":"tree.list"}
```

Информация по одной series:

```json
{"v":2,"op":"tree.info","series":"links"}
```

Ключи с cursor pagination:

```json
{"v":2,"op":"tree.keys","series":"links","limit":1000,"cursor":0}
```

Top keys:

```json
{"v":2,"op":"tree.top","series":"links","limit":100}
```

Summary:

```json
{"v":2,"op":"tree.summary","series":"links","range":{"from":20260501,"to":20260505}}
```

### Retention и обслуживание

Удалить старые buckets:

```json
{"v":2,"op":"series.delete_before","series":"links","before":20260401}
```

Compact одной series:

```json
{"v":2,"op":"series.compact","series":"links"}
```

Compact всех series:

```json
{"v":2,"op":"system.compact"}
```

Reset одного key или всей series:

```json
{"v":2,"op":"counter.reset","series":"links","key":42}
{"v":2,"op":"tree.reset","series":"links"}
```

Удалить range:

```json
{"v":2,"op":"counter.delete_range","series":"links","key":42,"range":{"from":20260501,"to":20260505}}
{"v":2,"op":"tree.delete_range","series":"links","range":{"from":20260501,"to":20260505}}
```

### Streaming ingest

Streaming ingest удобен для rebuild, backfill и больших импортов. Поддержанные
modes:

* `add`: добавить item values к live series;
* `set`: выставить bucket values в live series;
* `replace_series`: собрать staged series и атомарно заменить live series на
  `ingest.commit`.

Пример:

```json
{"v":2,"op":"ingest.begin","stream_id":"import-20260505","mode":"add","granularity":"day"}
{"v":2,"op":"ingest.chunk","stream_id":"import-20260505","series":"links","chunk_seq":1,"items":[[42,20260505,10]]}
{"v":2,"op":"ingest.commit","stream_id":"import-20260505"}
```

Прервать active stream:

```json
{"v":2,"op":"ingest.abort","stream_id":"import-20260505"}
```

Duplicate chunks пропускаются. Out-of-order chunks отклоняются до применения.
Stream привязывается к series, которая пришла в первом chunk.

## Snapshots, WAL и восстановление

Karma использует два механизма persistence:

* snapshots: MessagePack `.tree` files, по одному на series;
* WAL: newline-delimited JSON entries в `karma.wal`.

Создать и посмотреть snapshots:

```json
{"v":2,"op":"snapshot.create","series":"links"}
{"v":2,"op":"snapshot.create_all"}
{"v":2,"op":"snapshot.list"}
{"v":2,"op":"snapshot.info"}
```

Загрузить или скачать snapshot:

```json
{"v":2,"op":"snapshot.load","file":"1777925811_links.tree"}
{"v":2,"op":"snapshot.fetch","file":"1777925811_links.tree"}
{"v":2,"op":"snapshot.fetch_chunk","file":"1777925811_links.tree","offset":0,"limit":262144}
```

Проверить restore path:

```json
{"v":2,"op":"snapshot.verify"}
```

`snapshot.verify` восстанавливает данные во временный cluster и проверяет:

* sidecar metadata snapshots;
* согласованность `last_lsn` у latest snapshots;
* непрерывность WAL LSN;
* границы snapshot/WAL;
* persisted `karma.wal.lsn`.

Новые WAL lines используют LSN envelope:

```json
{"v":2,"lsn":1,"entry":{"v":2,"op":"counter.increment","tree":"links","key":42,"date":20260505,"value":1}}
```

Каждый новый snapshot имеет sidecar metadata file
`<snapshot>.meta.json`. Там хранятся `file`, `tree`, `timestamp`, `bytes` и
`last_lsn`.

Startup с `--restore=true`:

1. Загрузить latest snapshot для каждой series.
2. Replay-ить WAL entries.
3. На slave nodes инициализировать `karma.replication.lsn` из snapshot metadata
   перед polling master-а.

`snapshot.create_all` пишет atomic snapshots, делает fsync, truncates WAL после
успешного snapshotting и удаляет старые snapshots согласно
`--dump-retention-per-tree`.

Recovery checkpoints могут хранить позиции внешних источников, например
ClickHouse export id или durable queue offset:

```json
{"v":2,"op":"recovery.checkpoint","source":"clickhouse-links","offset":"export-2026-05-05","event_id":"batch-42"}
{"v":2,"op":"recovery.status"}
{"v":2,"op":"recovery.status","source":"clickhouse-links"}
```

Внешний reconciliation job может отправлять drift обратно в Karma:

```json
{"v":2,"op":"reconciliation.report","checked_points":1000,"mismatch_count":2,"absolute_drift":15,"max_abs_delta":10}
```

## Репликация

Karma поддерживает async master -> slave replication через snapshot bootstrap и
WAL polling.

Запуск slave:

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

Если директория slave пустая и `--restore=true`, slave скачает latest snapshots
с master через `snapshot.fetch_chunk`, выставит `karma.replication.lsn` из
snapshot metadata и затем начнет polling `replication.entries`.

Полезные команды:

```json
{"v":2,"op":"replication.status"}
{"v":2,"op":"replication.entries","after_lsn":120,"limit":1000}
```

`replication.entries` ограничен и по `limit`, и по `max_response_bytes` master-а.
Если response обрезан по byte budget, в нем будет `truncated_by_bytes: true`, а
`next_lsn` укажет на последнюю возвращенную entry.

Operational notes:

* slave nodes отклоняют прямые mutating client commands;
* failover ручной;
* перед promote slave нужно остановить старый master;
* остальные slave-ы нужно rebuild-ить от нового master;
* следите за `karma_replication_lag_entries`,
  `karma_replication_poll_errors_total` и
  `karma_replication_last_poll_success_unix`.

Подробный runbook: [docs/replication-operations-runbook.md](docs/replication-operations-runbook.md).

## Metrics и health

Базовые health checks:

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

Группы metrics:

* uptime, role, memory, trees, keys, snapshots;
* WAL bytes и current LSN;
* command counts, errors, latency и protocol v1 usage;
* batch read/write counters;
* retention и compaction counters;
* ingest stream counters и latency;
* reconciliation и recovery counters;
* replication lag, replayed LSN, polling/bootstrap success/error counters.

## Примеры клиентов

Через `nc`:

```sh
printf '{"v":2,"op":"counter.increment","series":"links","key":42,"value":1}\n' | nc 127.0.0.1 8080
printf '{"v":2,"op":"counter.sum","series":"links","key":42}\n' | nc 127.0.0.1 8080
```

На Crystal:

```crystal
require "json"
require "socket"

socket = TCPSocket.new("127.0.0.1", 8080)
socket << {v: 2, op: "counter.increment", series: "links", key: 42_u64, value: 1_u64}.to_json << "\n"
puts socket.gets
socket.close
```

На Ruby:

```ruby
require "json"
require "socket"

socket = TCPSocket.new("127.0.0.1", 8080)
socket.write({v: 2, op: "counter.sum", series: "links", key: 42}.to_json + "\n")
puts socket.gets
socket.close
```

## Performance checks

Локальные результаты зависят от CPU, диска, filesystem, container runtime,
network и профиля нагрузки. Эти скрипты нужны как повторяемые локальные
проверки, а не как универсальный benchmark.

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

CSV reconciliation против exported aggregates:

```sh
crystal run scripts/reconcile_csv.cr -- \
  --host=127.0.0.1 \
  --port=8080 \
  --series=links \
  --csv=clickhouse-links.csv \
  --report
```

## Signals

* `SIGINT`: перестать принимать новых TCP clients, сделать dump всех series,
  truncate WAL после успешных snapshots и выйти со status 0.
* `SIGUSR1`: сделать dump всех series, truncate WAL после успешных snapshots и
  продолжить работу.

## Разработка

Запуск тестов:

```sh
crystal spec
crystal spec lib/counter_tree/spec
```

Сборка:

```sh
shards build --release
```

Библиотека `counter_tree` vendored в `lib/counter_tree`, поэтому storage-часть
можно разрабатывать и тестировать внутри этого репозитория.

## Лицензия

MIT
