# Karma

Karma - небольшая служба TCP для быстрых счетчиков, разложенных по дням.

Она нужна там, где приложению на каждом запросе требуются свежие итоги по
множеству идентификаторов, а обращаться за этим к тяжелой аналитической базе
слишком дорого. Karma держит счетчики в памяти, сохраняет принятые записи через
снимки состояния и журнал упреждающей записи (WAL), а по сети принимает JSON по
одной строке на запрос.

Английская версия: [README.md](README.md).

## Для чего это нужно

Типичный поток:

```text
приложение читает основные объекты
  -> приложение просит Karma вернуть счетчики по идентификаторам
  -> ответ содержит свежие заранее посчитанные итоги
```

Karma - узкая модель быстрых чтений для счетчиков, а не универсальная база
временных рядов.

Поддерживается:

* беззнаковые 64-битные счетчики по ряду, ключу и дню UTC;
* одиночные и пакетные чтения/записи;
* идемпотентные записи для производителей с доставкой "как минимум один раз";
* большие перестроения данных через потоковую загрузку;
* снимки состояния, восстановление по журналу и проверка пути восстановления;
* асинхронная репликация от ведущего узла к ведомому через начальную загрузку
  снимков и чтение журнала;
* проверка состояния, статистика и метрики в формате, близком к Prometheus.

Не поддерживается: автоматический выбор ведущего узла, кворумные записи,
репликация в несколько ведущих узлов, произвольные метки временных рядов и
произвольные аналитические запросы.

## Быстрый запуск

Требования:

* Crystal 1.17.1
* Shards

Собрать и запустить:

```sh
shards build --release
bin/karma \
  --bind=127.0.0.1 \
  --port=8080 \
  --directory=.karma-data \
  --restore=true \
  --wal=true
```

Записать и прочитать счетчик:

```sh
printf '{"v":2,"op":"counter.increment","series":"links","key":42,"value":1}\n' \
  | nc 127.0.0.1 8080

printf '{"v":2,"op":"counter.sum","series":"links","key":42}\n' \
  | nc 127.0.0.1 8080
```

Обертка ответа:

```json
{"protocol_version":2,"success":true,"response":1,"error_code":null}
```

Запуск в Docker:

```sh
docker build -t karma:local .
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

Для промышленного запуска используйте постоянный диск, включенный журнал,
`--wal-fsync=true`, проверки состояния, сбор метрик и регулярные снимки через
`snapshot.create_all` или `SIGUSR1`.

## Модель данных

| Термин | Значение |
| --- | --- |
| `series` | Именованный ряд счетчиков, например `links` или `domains`. |
| `key` | Беззнаковый 64-битный идентификатор внутри ряда. |
| `bucket` | День UTC в формате `YYYYMMDD`. Если день не указан при записи, используется текущий день UTC. |
| `value` | Беззнаковое 64-битное значение. Счетчики не уходят ниже нуля. |

Команды чтения не создают отсутствующие ряды. Если ряд не найден, Karma
возвращает `not_found`; если в существующем ряду нет ключа, возвращается ноль
или пустой результат.

## Протокол

Karma 1.0 принимает только протокол v2:

* один запрос - один JSON-объект и `\n`;
* один ответ - один JSON-объект и `\r\n`;
* в каждом запросе должны быть `"v": 2` и поле `op`.

Пример:

```json
{"v":2,"op":"counter.increment","series":"links","key":42,"bucket":20260505,"value":1}
```

Ответ с ошибкой:

```json
{
  "protocol_version": 2,
  "success": false,
  "response": "Field tree or series is required",
  "error_code": "validation_error"
}
```

Устойчивые коды ошибок:

| Код | Значение |
| --- | --- |
| `invalid_json` | Тело запроса не является корректным JSON. |
| `unsupported_protocol` | Запрос не соответствует протоколу v2. |
| `unknown_command` | Неизвестное значение `op`. |
| `validation_error` | Неверная форма запроса или недопустимое значение. |
| `not_found` | Запрошенный ряд или файл не существует. |
| `unauthorized` | Нет токена или токен неверный. |
| `forbidden` | Команда запрещена для роли узла или токена. |
| `request_too_large` | Запрос больше `--max-request-bytes`. |
| `response_too_large` | Ответ больше `--max-response-bytes`. |
| `query_timeout` | Большое чтение превысило `--query-timeout-ms`. |
| `idempotency_conflict` | Ключ идемпотентности повторно использован с другим запросом. |
| `replication_gap` | Запрошенного диапазона журнала уже нет. |
| `replication_error` | Ошибка начальной загрузки или чтения репликации. |
| `internal_error` | Непредвиденная ошибка на стороне сервера. |

Если задан `--auth-token`, каждый клиентский запрос должен передавать `token`.
Если задан `--read-auth-token`, этот токен может выполнять только команды
чтения. Токены никогда не пишутся в журнал.

## Основные операции

### Счетчики

```json
{"v":2,"op":"tree.create","series":"links"}
{"v":2,"op":"counter.increment","series":"links","key":42,"value":1}
{"v":2,"op":"counter.increment","series":"links","key":42,"bucket":20260505,"value":10}
{"v":2,"op":"counter.decrement","series":"links","key":42,"bucket":20260505,"value":1}
{"v":2,"op":"counter.sum","series":"links","key":42}
{"v":2,"op":"counter.sum","series":"links","key":42,"range":{"from":20260501,"to":20260505}}
{"v":2,"op":"counter.series","series":"links","key":42,"range":{"from":20260501,"to":20260505}}
```

### Пакетные чтения и записи

```json
{"v":2,"op":"counter.batch_sum","series":"links","keys":[41,42,43]}
{"v":2,"op":"counter.batch_sum","series":"links","keys":[41,42,43],"range":{"from":20260501,"to":20260505}}
{"v":2,"op":"counter.multi_sum","items":[{"series":"links","key":101},{"series":"domains","key":101}]}
{"v":2,"op":"series.batch_add","series":"links","items":[[42,20260505,10],[43,20260505,3]]}
{"v":2,"op":"series.batch_set","series":"links","items":[[42,20260505,10],[43,20260505,0]]}
```

`series.batch_set` записывает точные значения по дням. Нулевое значение удаляет
этот день из счетчика. Большие запросы должны укладываться в
`--max-request-bytes`.

### Просмотр и обслуживание рядов

```json
{"v":2,"op":"tree.list"}
{"v":2,"op":"tree.info","series":"links"}
{"v":2,"op":"tree.keys","series":"links","limit":1000,"cursor":0}
{"v":2,"op":"tree.summary","series":"links","range":{"from":20260501,"to":20260505}}
{"v":2,"op":"tree.top","series":"links","limit":100}
{"v":2,"op":"series.delete_before","series":"links","before":20260401}
{"v":2,"op":"series.compact","series":"links"}
{"v":2,"op":"system.compact"}
```

### Удаление и сброс

```json
{"v":2,"op":"counter.reset","series":"links","key":42}
{"v":2,"op":"counter.batch_reset","series":"links","keys":[41,42,43]}
{"v":2,"op":"tree.reset","series":"links"}
{"v":2,"op":"counter.delete_range","series":"links","key":42,"range":{"from":20260501,"to":20260505}}
{"v":2,"op":"counter.batch_delete_range","series":"links","keys":[41,42,43],"range":{"from":20260501,"to":20260505}}
{"v":2,"op":"tree.delete_range","series":"links","range":{"from":20260501,"to":20260505}}
```

## Идемпотентные записи

Изменяющие команды могут передавать `idempotency_key`. Karma сохраняет первый
успешный ответ для этого ключа. Повтор такого же запроса вернет сохраненный
ответ с `"idempotent": true`; повторное использование ключа с другим запросом
вернет `idempotency_conflict`.

Пример:

```json
{"v":2,"op":"counter.increment","series":"links","key":42,"bucket":20260505,"value":1,"idempotency_key":"click-event-123"}
```

Поддерживаемые команды:

* `counter.increment`, `counter.decrement`;
* `series.batch_add`, `series.batch_set`;
* `counter.reset`, `counter.batch_reset`;
* `counter.delete_range`, `counter.batch_delete_range`;
* `tree.reset`, `tree.delete_range`.

Записи идемпотентности сохраняются через журнал и снимки состояния. Хранение
ограничивается параметрами `--idempotency-max-records`,
`--idempotency-max-age-seconds` и ручной очисткой:

```json
{"v":2,"op":"idempotency.prune","before":"2026-05-29T00:00:00Z","limit":10000}
```

## Потоковая загрузка

Потоковая загрузка нужна для перестроений, дозагрузок и больших импортов.

| Режим | Поведение |
| --- | --- |
| `add` | Добавить значения к текущему ряду. |
| `set` | Установить точные значения по дням в текущем ряду. |
| `replace_series` | Собрать временный ряд и атомарно заменить им текущий ряд при подтверждении. |

Пример:

```json
{"v":2,"op":"ingest.begin","stream_id":"import-20260505","mode":"add","granularity":"day"}
{"v":2,"op":"ingest.chunk","stream_id":"import-20260505","series":"links","chunk_seq":1,"items":[[42,20260505,10]]}
{"v":2,"op":"ingest.commit","stream_id":"import-20260505"}
```

Отменить активную загрузку:

```json
{"v":2,"op":"ingest.abort","stream_id":"import-20260505"}
```

Повторные части пропускаются. Части не по порядку отклоняются до применения.
Поток привязывается к ряду из первой части. Подтвержденные потоки запоминаются
на диске, поэтому повторный `replace_series` после перезапуска, восстановления
или репликации не заменит ряд второй раз.

## Сохранение и восстановление

Karma сохраняет данные двумя способами:

* снимки состояния: файлы MessagePack `.tree`, по одному на ряд;
* журнал: JSON-записи в `karma.wal`, по одной строке на запись.

По умолчанию активный журнал ротируется на 64 МиБ. Закрытые файлы называются
`karma.wal.<first_lsn>.segment` и могут иметь служебные индексные файлы
`*.segment.idx`, где LSN сопоставлен с позицией в файле для быстрого догоняющего
чтения репликации.

Команды снимков:

```json
{"v":2,"op":"snapshot.create","series":"links"}
{"v":2,"op":"snapshot.create_all"}
{"v":2,"op":"snapshot.list"}
{"v":2,"op":"snapshot.info"}
{"v":2,"op":"snapshot.verify"}
```

Скачать или загрузить снимок:

```json
{"v":2,"op":"snapshot.load","file":"1777925811_links.tree"}
{"v":2,"op":"snapshot.fetch","file":"1777925811_links.tree"}
{"v":2,"op":"snapshot.fetch_chunk","file":"1777925811_links.tree","offset":0,"limit":262144}
```

Новые записи журнала используют v2-обертку с LSN:

```json
{"v":2,"lsn":1,"entry":{"v":2,"op":"counter.increment","series":"links","key":42,"bucket":20260505,"value":1}}
```

При старте с `--restore=true` Karma загружает последний снимок каждого ряда и
проигрывает записи журнала после LSN снимка. `snapshot.create_all` атомарно
пишет снимки, вызывает fsync, очищает журнал после успешного снимка и удаляет
старые снимки согласно `--dump-retention-per-tree`.

Метки восстановления для внешних процессов:

```json
{"v":2,"op":"recovery.checkpoint","source":"clickhouse-links","offset":"export-2026-05-05","event_id":"batch-42"}
{"v":2,"op":"recovery.status"}
{"v":2,"op":"recovery.status","source":"clickhouse-links"}
{"v":2,"op":"reconciliation.report","checked_points":1000,"mismatch_count":2,"absolute_drift":15,"max_abs_delta":10}
```

## Репликация

Karma поддерживает асинхронную репликацию от ведущего узла к ведомому. Ведомый
узел может начать со снимков ведущего, а затем периодически читать журнал.

Запустить ведомый узел:

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

Полезные запросы:

```json
{"v":2,"op":"replication.status"}
{"v":2,"op":"replication.entries","after_lsn":120,"limit":1000}
```

Эксплуатационные ограничения:

* репликация асинхронная;
* ведомые узлы отклоняют прямые изменяющие команды клиентов;
* переключение на другой ведущий узел выполняется вручную;
* перед повышением ведомого узла остановите старый ведущий;
* остальные ведомые узлы нужно перестроить от нового ведущего.

Подробная инструкция: [docs/replication-operations-runbook.md](docs/replication-operations-runbook.md).

## Настройка

Параметры запуска имеют приоритет над переменными окружения. Логические
значения: `true` или `false`. Таймауты указаны в секундах, кроме параметров с
суффиксом `-ms`.

| Параметр | Переменная | По умолчанию | Значение |
| --- | --- | ---: | --- |
| `--bind=host` | `KARMA_HOST` | `0.0.0.0` | Адрес для прослушивания. |
| `--port=port` | `KARMA_PORT` | `8080` | Порт TCP. |
| `--directory=path` | `KARMA_DUMP_DIR` | `.` | Каталог для снимков, журнала и служебных файлов. |
| `--role=master\|slave` | `KARMA_ROLE` | `master` | Роль узла. |
| `--restore=true\|false` | `KARMA_RESTORE` | `true` | Восстанавливать снимки и журнал при запуске. |
| `--nodelay=true\|false` | `KARMA_TCP_NODELAY` | `true` | Включить TCP_NODELAY. |
| `--wal=true\|false` | `KARMA_WAL` | `true` | Писать изменяющие команды в журнал. |
| `--wal-fsync=true\|false` | `KARMA_WAL_FSYNC` | `true` | Вызывать fsync для записей журнала и его очистки. |
| `--wal-segment-bytes=bytes` | `KARMA_WAL_SEGMENT_BYTES` | `67108864` | Ротировать журнал после такого числа байт; `0` отключает ротацию. |
| `--wal-batch-size=count` | `KARMA_WAL_BATCH_SIZE` | `1024` | Максимум записей журнала в одной пачке потока записи. |
| `--wal-batch-wait-us=microseconds` | `KARMA_WAL_BATCH_WAIT_MICROSECONDS` | `0` | Максимальное ожидание потока записи для добора записей в пачку. |
| `--max-request-bytes=bytes` | `KARMA_MAX_REQUEST_BYTES` | `4096` | Максимальный размер строки JSON-запроса. |
| `--max-response-bytes=bytes` | `KARMA_MAX_RESPONSE_BYTES` | `1048576` | Максимальный размер JSON-ответа; `0` отключает лимит. |
| `--read-timeout=seconds` | `KARMA_READ_TIMEOUT_SECONDS` | `5` | Таймаут чтения из клиентского сокета; `0` отключает. |
| `--write-timeout=seconds` | `KARMA_WRITE_TIMEOUT_SECONDS` | `5` | Таймаут записи в клиентский сокет; `0` отключает. |
| `--query-timeout-ms=ms` | `KARMA_QUERY_TIMEOUT_MS` | `1000` | Таймаут больших чтений; `0` отключает. |
| `--shutdown-timeout=seconds` | `KARMA_SHUTDOWN_TIMEOUT_SECONDS` | `5` | Сколько ждать активных клиентов при остановке. |
| `--auth-token=token` | `KARMA_AUTH_TOKEN` | не задано | Токен, обязательный для всех команд. |
| `--read-auth-token=token` | `KARMA_READ_AUTH_TOKEN` | не задано | Токен только для команд чтения. |
| `--dump-retention-per-tree=count` | `KARMA_DUMP_RETENTION_PER_TREE` | `5` | Сколько снимков хранить на ряд после `snapshot.create_all`. |
| `--idempotency-max-records=count` | `KARMA_IDEMPOTENCY_MAX_RECORDS` | `1000000` | Максимум записей идемпотентности. |
| `--idempotency-max-age-seconds=seconds` | `KARMA_IDEMPOTENCY_MAX_AGE_SECONDS` | `604800` | Максимальный возраст записи идемпотентности; `0` отключает очистку по возрасту. |
| `--replication-source-host=host` | `KARMA_REPLICATION_SOURCE_HOST` | не задано | Адрес ведущего узла для ведомого. |
| `--replication-source-port=port` | `KARMA_REPLICATION_SOURCE_PORT` | `8080` | Порт ведущего узла для ведомого. |
| `--replication-token=token` | `KARMA_REPLICATION_TOKEN` | не задано | Токен для запросов репликации. |
| `--replication-poll-interval-ms=ms` | `KARMA_REPLICATION_POLL_INTERVAL_MS` | `1000` | Интервал чтения журнала ведомым узлом. |
| `--replication-batch-size=count` | `KARMA_REPLICATION_BATCH_SIZE` | `1000` | Максимум записей журнала за один опрос ведомого. |
| `--log=true\|false` | `KARMA_LOG` | `true` | Писать структурированные JSON-логи. |

## Состояние и метрики

```json
{"v":2,"op":"system.ping"}
{"v":2,"op":"system.health"}
{"v":2,"op":"system.stats"}
{"v":2,"op":"system.metrics"}
```

Метрики включают время работы, роль, расход памяти, число рядов и ключей,
размер журнала и текущий LSN, число команд и задержки, пакетные счетчики,
потоковую загрузку, идемпотентность, восстановление, сверку данных и состояние
репликации.

В промышленной среде особенно полезны:

* `karma_replication_lag_entries`
* `karma_replication_poll_errors_total`
* `karma_replication_last_poll_success_unix`
* `karma_errors_total`
* `karma_query_timeouts_total`

## Клиенты

Клиент Ruby/Rails:

```ruby
gem "karma_client", path: "clients/ruby"
```

Клиент использует протокол v2 поверх TCP и JSON, преобразует устойчивые коды
ошибок Karma в исключения Ruby, поддерживает явные таймауты подключения,
чтения и записи, а также небольшой пул соединений для Puma/Sidekiq.

Минимальный запрос на Ruby:

```ruby
require "json"
require "socket"

socket = TCPSocket.new("127.0.0.1", 8080)
socket.write({v: 2, op: "counter.sum", series: "links", key: 42}.to_json + "\n")
puts socket.gets
socket.close
```

## Проверки производительности

Локальные результаты зависят от процессора, диска, файловой системы, среды
запуска, сети и профиля нагрузки. Их стоит читать как локальные проверки
регрессий, а не как универсальные обещания.

Последняя запись результатов: 6 июня 2026.

| Проверка | Режим | Производительность | Задержка p95 |
| --- | --- | ---: | ---: |
| `single_increment` | внутри процесса, журнал выключен | 390 785 оп/с | 0.0026 мс |
| `single_sum` | внутри процесса, журнал выключен | 568 529 оп/с | 0.0019 мс |
| `series.batch_add` | внутри процесса, журнал выключен | 2 288 199 элементов/с | 1.1090 мс |
| `counter.batch_sum` | внутри процесса, журнал выключен | 2 474 548 ключей/с | 0.9126 мс |
| `tcp_single_increment` | TCP, 4 клиента, журнал выключен | 36 728 оп/с | 0.1580 мс |
| `tcp_single_sum` | TCP, 4 клиента, журнал выключен | 40 614 оп/с | 0.1278 мс |
| `tcp_series.batch_add` | TCP, 4 клиента, журнал выключен | 1 457 823 элементов/с | 2.5373 мс |
| `tcp_counter.batch_sum` | TCP, 4 клиента, журнал выключен | 2 275 990 ключей/с | 2.1863 мс |
| `tcp_single_increment` | TCP, 4 клиента, журнал включен, fsync выключен | 21 077 оп/с | 0.2369 мс |
| `tcp_single_sum` | TCP, 4 клиента, журнал включен, fsync выключен | 37 927 оп/с | 0.1458 мс |
| `tcp_series.batch_add` | TCP, 4 клиента, журнал включен, fsync выключен | 1 109 765 элементов/с | 5.4988 мс |
| `tcp_counter.batch_sum` | TCP, 4 клиента, журнал включен, fsync выключен | 2 278 534 ключей/с | 2.5800 мс |

Дополнительные проверки из того же прогона:

* идемпотентный `counter.increment`, журнал выключен, JSON-запросы подготовлены
  заранее: около 506 918 оп/с без `idempotency_key` и около 205 914 оп/с с
  уникальными ключами;
* 100 000 ключей по 7 дней: `counter.batch_sum` прочитал около 1 505 471
  ключа/с;
* 50 000 ключей по 356 дней: `counter.batch_sum` прочитал около 1 946 673
  ключей/с;
* проверка репликации завершилась без отставания, итоги ведущего и ведомого
  узлов совпали;
* сегментированный журнал на 1 000 000 записей прочитал холодную страницу из
  индексированного сегмента за 83.23 мс против 253.36 мс без служебного индекса.

Повторить основные проверки:

```sh
crystal build --release scripts/load_test.cr -o bin/karma_load_test
bin/karma_load_test

crystal build --release scripts/tcp_load_test.cr -o bin/karma_tcp_load_test
bin/karma_tcp_load_test --clients=4 --wal=true --wal-fsync=false
```

Остальные скрипты находятся в [scripts](scripts).

## Сигналы

* `SIGINT`: перестать принимать новых TCP-клиентов, сделать снимок всех рядов,
  очистить журнал после успешных снимков и выйти со статусом 0.
* `SIGUSR1`: сделать снимок всех рядов, очистить журнал после успешных снимков
  и продолжить работу.

## Разработка

```sh
crystal spec
crystal spec lib/counter_tree/spec
shards build --release
```

Библиотека `counter_tree` хранится внутри репозитория:
[lib/counter_tree](lib/counter_tree).

## Лицензия

MIT
