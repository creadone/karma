<p align="center">
  <img src="https://raw.githubusercontent.com/creadone/karma/master/docs/karma.png" height="200">
  <h3 align="center">Karma</h3>
</p>

Karma - небольшая TCP-база данных для горячих временных счетчиков. Она нужна
там, где приложению важно быстро получать свежие агрегированные счетчики и не
дергать тяжелое аналитическое хранилище на каждый пользовательский запрос.

Типичный сценарий:

```text
приложение читает метаданные ссылок
  -> приложение запрашивает в Karma счетчики для набора id ссылок
  -> клиент получает список ссылок со свежими счетчиками кликов
```

Karma хранит данные в памяти, сохраняет их через снимки состояния и WAL, а
наружу отдает простой JSON-протокол поверх TCP: один запрос - одна строка.

Английская версия: [README.md](README.md).

## Статус

Karma сейчас лучше рассматривать как рабочую модель чтения горячих счетчиков,
а не как универсальную базу временных рядов.

Что уже поддерживается:

* счетчики по дням в формате `YYYYMMDD`;
* одиночные чтения и записи;
* пакетные чтения и записи;
* потоковая загрузка для пересборки и дозагрузки данных;
* атомарные снимки состояния и восстановление через WAL;
* контрольные точки восстановления и отчеты сверки данных;
* асинхронная репликация master -> slave через загрузку снимка состояния и
  чтение WAL;
* эксплуатационные метрики в формате, близком к Prometheus.

Важные границы текущей версии:

* выполнение команд сериализовано одной блокировкой внутри процесса;
* репликация асинхронная, переключение на новый master выполняется вручную;
* автоматического выбора ведущего узла, кворума и режима записи в несколько
  master-узлов нет;
* передача снимков состояния через объектное хранилище и команда
  `replication.subscribe` пока не реализованы.

Для боевого запуска используйте постоянный диск, включенный WAL,
`--wal-fsync=true`, проверками здоровья, сбором метрик и регулярными
снимками состояния через `snapshot.create_all` или `SIGUSR1`.

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

Собрать образ Docker:

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

Рекомендуемый запуск master-узла:

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

Ту же конфигурацию можно задать переменными окружения. Параметры командной
строки применяются после переменных окружения и переопределяют их:

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

Логические значения задаются как `true` или `false`. Таймауты указываются в
секундах, кроме опций, где явно написано `-ms`.

| Опция запуска | Переменная окружения | Значение по умолчанию | Описание |
| --- | --- | ---: | --- |
| `--bind=host` | `KARMA_HOST` | `0.0.0.0` | Адрес, на котором слушает сервер. |
| `--port=port` | `KARMA_PORT` | `8080` | TCP-порт. |
| `--directory=path` | `KARMA_DUMP_DIR` | `.` | Директория для снимков состояния, WAL и служебных файлов. |
| `--role=master\|slave` | `KARMA_ROLE` | `master` | Роль узла. |
| `--restore=true\|false` | `KARMA_RESTORE` | `true` | Загружать снимки состояния и проигрывать WAL при старте. |
| `--nodelay=true\|false` | `KARMA_TCP_NODELAY` | `true` | Включить TCP_NODELAY. |
| `--wal=true\|false` | `KARMA_WAL` | `true` | Писать изменяющие команды в WAL. |
| `--wal-fsync=true\|false` | `KARMA_WAL_FSYNC` | `true` | Делать fsync на каждую запись и очистку WAL. |
| `--max-request-bytes=bytes` | `KARMA_MAX_REQUEST_BYTES` | `4096` | Максимальный размер строки JSON-запроса. Должен быть больше 0. |
| `--max-response-bytes=bytes` | `KARMA_MAX_RESPONSE_BYTES` | `1048576` | Максимальный размер JSON-ответа. `0` отключает лимит. |
| `--read-timeout=seconds` | `KARMA_READ_TIMEOUT_SECONDS` | `5` | Таймаут чтения из сокета. `0` отключает. |
| `--write-timeout=seconds` | `KARMA_WRITE_TIMEOUT_SECONDS` | `5` | Таймаут записи в сокет. `0` отключает. |
| `--query-timeout-ms=ms` | `KARMA_QUERY_TIMEOUT_MS` | `1000` | Таймаут для дорогих чтений всей series. `0` отключает. |
| `--shutdown-timeout=seconds` | `KARMA_SHUTDOWN_TIMEOUT_SECONDS` | `5` | Сколько ждать активных клиентов при аккуратной остановке. |
| `--auth-token=token` | `KARMA_AUTH_TOKEN` | не задано | Токен, обязательный для всех команд. Пустое значение переменной окружения отключает проверку. |
| `--read-auth-token=token` | `KARMA_READ_AUTH_TOKEN` | не задано | Токен только для команд чтения. Пустое значение переменной окружения отключает проверку. |
| `--dump-retention-per-tree=count` | `KARMA_DUMP_RETENTION_PER_TREE` | `5` | Сколько снимков состояния хранить на series после `snapshot.create_all`. |
| `--replication-source-host=host` | `KARMA_REPLICATION_SOURCE_HOST` | не задано | Адрес master-узла, который будет читать slave. |
| `--replication-source-port=port` | `KARMA_REPLICATION_SOURCE_PORT` | `8080` | Порт master-узла, который будет читать slave. |
| `--replication-token=token` | `KARMA_REPLICATION_TOKEN` | не задано | Токен для запросов репликации со slave. |
| `--replication-poll-interval-ms=ms` | `KARMA_REPLICATION_POLL_INTERVAL_MS` | `1000` | Как часто slave опрашивает master. |
| `--replication-batch-size=count` | `KARMA_REPLICATION_BATCH_SIZE` | `1000` | Максимум WAL-записей за один опрос со slave. Максимум: 10000. |
| `--log=true\|false` | `KARMA_LOG` | `true` | Писать структурированные JSON-логи. |

## Протокол

Karma использует JSON поверх TCP: один запрос - одна строка.

* один запрос - один JSON-объект и `\n`;
* один ответ - один JSON-объект и `\r\n`.

Для новых клиентов предпочтителен протокол v2. В нем есть `v: 2`,
пространства имен в поле `op` и терминология `series/key/bucket/value`:

```json
{"v":2,"op":"counter.increment","series":"links","key":42,"bucket":20260505,"value":1}
```

Старый протокол v1 остается для совместимости и восстановления старых WAL.
Такие запросы используют `command`, `tree_name`, `date`,
`time_from`/`time_to`. Новым клиентам лучше использовать v2.

Успешный ответ:

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

Стабильные коды ошибок:

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

Если настроен `--auth-token`, добавляйте `token` в каждый клиентский запрос.
Если настроен `--read-auth-token`, этот токен может выполнять только команды
чтения. Токены не пишутся в WAL.

## Модель данных

* **series** - именованная коллекция счетчиков. Внутреннее хранилище и старый
  API еще используют слово `tree`.
* **key** - беззнаковое 64-битное целое число внутри series.
* **bucket** - UTC-день в формате `YYYYMMDD`, например `20260505`.
* **value** - беззнаковое 64-битное целое число.
* `counter.increment` и `counter.decrement` используют сегодняшний UTC-день,
  если `bucket` не задан.
* Значения счетчиков никогда не уходят ниже нуля.

Команды чтения не создают отсутствующие series. Если series не найдена, Karma
возвращает `not_found`. Для существующей series отсутствующий key возвращает
ноль или пустой результат.

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

Увеличить счетчик за конкретный день:

```json
{"v":2,"op":"counter.increment","series":"links","key":42,"bucket":20260505,"value":1}
```

Уменьшить счетчик:

```json
{"v":2,"op":"counter.decrement","series":"links","key":42,"bucket":20260505,"value":1}
```

Прочитать сумму по key:

```json
{"v":2,"op":"counter.sum","series":"links","key":42}
```

Прочитать диапазон дат:

```json
{"v":2,"op":"counter.sum","series":"links","key":42,"range":{"from":20260501,"to":20260505}}
```

Прочитать дневные значения:

```json
{"v":2,"op":"counter.series","series":"links","key":42,"range":{"from":20260501,"to":20260505}}
```

### Пакетное чтение и запись

Прочитать много сумм одним запросом:

```json
{"v":2,"op":"counter.batch_sum","series":"links","keys":[41,42,43]}
```

Прочитать много сумм за диапазон дат:

```json
{"v":2,"op":"counter.batch_sum","series":"links","keys":[41,42,43],"range":{"from":20260501,"to":20260505}}
```

Добавить много элементов `[key, bucket, value]`:

```json
{"v":2,"op":"series.batch_add","series":"links","items":[[42,20260505,10],[43,20260505,3]]}
```

Большие пакетные запросы должны помещаться в `--max-request-bytes`.

### Просмотр series

Список series:

```json
{"v":2,"op":"tree.list"}
```

Информация по одной series:

```json
{"v":2,"op":"tree.info","series":"links"}
```

Ключи с постраничной выдачей через курсор:

```json
{"v":2,"op":"tree.keys","series":"links","limit":1000,"cursor":0}
```

Ключи с самыми большими значениями:

```json
{"v":2,"op":"tree.top","series":"links","limit":100}
```

Сводка:

```json
{"v":2,"op":"tree.summary","series":"links","range":{"from":20260501,"to":20260505}}
```

### Хранение старых данных и обслуживание

Удалить старые дневные значения:

```json
{"v":2,"op":"series.delete_before","series":"links","before":20260401}
```

Уплотнить одну series:

```json
{"v":2,"op":"series.compact","series":"links"}
```

Уплотнить все series:

```json
{"v":2,"op":"system.compact"}
```

Сбросить один key или всю series:

```json
{"v":2,"op":"counter.reset","series":"links","key":42}
{"v":2,"op":"tree.reset","series":"links"}
```

Удалить диапазон дат:

```json
{"v":2,"op":"counter.delete_range","series":"links","key":42,"range":{"from":20260501,"to":20260505}}
{"v":2,"op":"tree.delete_range","series":"links","range":{"from":20260501,"to":20260505}}
```

### Потоковая загрузка

Потоковая загрузка удобна для пересборки, дозагрузки истории и больших
импортов. Поддержанные режимы:

* `add`: добавить значения элементов к рабочей series;
* `set`: выставить дневные значения в рабочей series;
* `replace_series`: собрать новую series отдельно и атомарно заменить рабочую
  series на `ingest.commit`.

Пример:

```json
{"v":2,"op":"ingest.begin","stream_id":"import-20260505","mode":"add","granularity":"day"}
{"v":2,"op":"ingest.chunk","stream_id":"import-20260505","series":"links","chunk_seq":1,"items":[[42,20260505,10]]}
{"v":2,"op":"ingest.commit","stream_id":"import-20260505"}
```

Прервать активный поток:

```json
{"v":2,"op":"ingest.abort","stream_id":"import-20260505"}
```

Повторные фрагменты загрузки пропускаются. Фрагменты не по порядку
отклоняются до применения. Поток привязывается к series, которая пришла в
первом фрагменте.

## Снимки состояния, WAL и восстановление

Karma использует два механизма сохранения данных:

* снимки состояния: MessagePack-файлы `.tree`, по одному на series;
* WAL: JSON-записи в `karma.wal`, по одной записи на строку.

Создать и посмотреть снимки состояния:

```json
{"v":2,"op":"snapshot.create","series":"links"}
{"v":2,"op":"snapshot.create_all"}
{"v":2,"op":"snapshot.list"}
{"v":2,"op":"snapshot.info"}
```

Загрузить или скачать снимок состояния:

```json
{"v":2,"op":"snapshot.load","file":"1777925811_links.tree"}
{"v":2,"op":"snapshot.fetch","file":"1777925811_links.tree"}
{"v":2,"op":"snapshot.fetch_chunk","file":"1777925811_links.tree","offset":0,"limit":262144}
```

Проверить путь восстановления:

```json
{"v":2,"op":"snapshot.verify"}
```

`snapshot.verify` восстанавливает данные во временный кластер и проверяет:

* служебные данные снимков состояния;
* согласованность `last_lsn` у последних снимков состояния;
* непрерывность WAL LSN;
* границы между снимком состояния и WAL;
* сохраненный файл `karma.wal.lsn`.

Новые строки WAL используют обертку с LSN:

```json
{"v":2,"lsn":1,"entry":{"v":2,"op":"counter.increment","tree":"links","key":42,"date":20260505,"value":1}}
```

У каждого нового снимка состояния есть служебный файл метаданных
`<snapshot>.meta.json`. Там хранятся `file`, `tree`, `timestamp`, `bytes` и
`last_lsn`.

Старт с `--restore=true`:

1. Загрузить последний снимок состояния для каждой series.
2. Проиграть WAL-записи.
3. На slave-узлах инициализировать `karma.replication.lsn` из метаданных
   снимка состояния перед опросом master-а.

`snapshot.create_all` пишет снимки состояния атомарно, делает fsync, очищает
WAL после успешного создания снимков и удаляет старые файлы согласно
`--dump-retention-per-tree`.

Контрольные точки восстановления могут хранить позиции внешних источников,
например id экспорта из ClickHouse или позицию в надежной очереди:

```json
{"v":2,"op":"recovery.checkpoint","source":"clickhouse-links","offset":"export-2026-05-05","event_id":"batch-42"}
{"v":2,"op":"recovery.status"}
{"v":2,"op":"recovery.status","source":"clickhouse-links"}
```

Внешняя задача сверки может отправлять информацию о расхождениях обратно в
Karma:

```json
{"v":2,"op":"reconciliation.report","checked_points":1000,"mismatch_count":2,"absolute_drift":15,"max_abs_delta":10}
```

## Репликация

Karma поддерживает асинхронную репликацию master -> slave через начальную
загрузку снимков состояния и периодическое чтение WAL.

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

Если директория slave пустая и `--restore=true`, slave скачает последние
снимки состояния с master через `snapshot.fetch_chunk`, выставит
`karma.replication.lsn` из метаданных снимка состояния и затем начнет опрашивать
`replication.entries`.

Полезные команды:

```json
{"v":2,"op":"replication.status"}
{"v":2,"op":"replication.entries","after_lsn":120,"limit":1000}
```

`replication.entries` ограничен и по `limit`, и по `max_response_bytes`
master-а. Если ответ обрезан по лимиту размера, в нем будет
`truncated_by_bytes: true`, а `next_lsn` укажет на последнюю возвращенную
WAL-запись.

Эксплуатационные заметки:

* slave-узлы отклоняют прямые клиентские команды записи;
* переключение на новый master выполняется вручную;
* перед повышением slave до master нужно остановить старый master;
* остальные slave-ы нужно пересобрать от нового master;
* следите за `karma_replication_lag_entries`,
  `karma_replication_poll_errors_total` и
  `karma_replication_last_poll_success_unix`.

Подробная инструкция по эксплуатации:
[docs/replication-operations-runbook.md](docs/replication-operations-runbook.md).

## Метрики и проверки здоровья

Базовые проверки здоровья:

```json
{"v":2,"op":"system.ping"}
{"v":2,"op":"system.health"}
```

Эксплуатационная статистика:

```json
{"v":2,"op":"system.stats"}
```

Метрики в формате, близком к Prometheus:

```json
{"v":2,"op":"system.metrics"}
```

Группы метрик:

* время работы, роль узла, память, series, keys и снимки состояния;
* размер WAL и текущий LSN;
* счетчики команд, ошибок, задержек и использования протокола v1;
* счетчики пакетных чтений и записей;
* счетчики удаления старых данных и уплотнения;
* счетчики потоковой загрузки и ее задержка;
* счетчики сверки данных и восстановления;
* отставание репликации, примененный LSN, успешные и ошибочные опросы и
  начальные загрузки.

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

## Проверки производительности

Локальные результаты зависят от CPU, диска, файловой системы, контейнерной
среды, сети и профиля нагрузки. Эти скрипты нужны как повторяемые локальные
проверки, а не как универсальный бенчмарк.

Последние зафиксированные локальные результаты от 5 мая 2026:

| Тест | Режим | Производительность | p95 задержка |
| --- | --- | ---: | ---: |
| `single_increment` | внутри процесса, WAL выключен | 289 908 ops/sec | 0.004 ms |
| `single_sum` | внутри процесса, WAL выключен | 403 080 ops/sec | 0.0026 ms |
| `series.batch_add` | внутри процесса, WAL выключен | 1 917 010 items/sec | 0.9878 ms |
| `counter.batch_sum` | внутри процесса, WAL выключен | 2 389 520 key reads/sec | 0.8685 ms |
| `tcp_single_increment` | TCP, 4 клиента, WAL включен, fsync включен | 12 818 ops/sec | 0.5561 ms |
| `tcp_single_sum` | TCP, 4 клиента, WAL включен, fsync включен | 41 340 ops/sec | 0.1339 ms |
| `tcp_series.batch_add` | TCP, 4 клиента, WAL включен, fsync включен | 744 551 items/sec | 2.9103 ms |
| `tcp_counter.batch_sum` | TCP, 4 клиента, WAL включен, fsync включен | 1 708 312 key reads/sec | 1.5604 ms |

Тест зависимости от объема данных: внутри процесса, WAL выключен, 7 дневных
bucket-ов на ключ:

| Ключи | Точек данных | Память | Снимок | Пакетное чтение | p95 пакета | Сводка | Снимок | Восстановление |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 10 000 | 70 000 | 8.23 MiB | 0.57 MiB | 2 255 027 key reads/sec | 0.8820 ms | 4.59 ms | 4.59 ms | 2.87 ms |
| 50 000 | 350 000 | 28.48 MiB | 2.86 MiB | 1 778 740 key reads/sec | 0.4863 ms | 33.41 ms | 20.35 ms | 15.18 ms |
| 100 000 | 700 000 | 47.70 MiB | 5.79 MiB | 1 558 846 key reads/sec | 0.4809 ms | 88.58 ms | 42.81 ms | 32.21 ms |

Тест репликации в тот же день запускался с `clients=4`, `keys=10000`,
`batch_size=1000`, `write_batches=100`, `read_rounds=100`,
`replication_poll_interval_ms=10` и `replication_batch_size=1000`.
Slave поднялся из снимка состояния, проиграл WAL с LSN 10 до LSN 110,
завершил прогон с `final_lag_entries=0`, а итоговые суммы совпали:
`master_total=110000`, `slave_total=110000`.

Тест слоя команд внутри процесса:

```sh
crystal build --release scripts/load_test.cr -o bin/karma_load_test
bin/karma_load_test
```

TCP-тест на локальной машине:

```sh
crystal build --release scripts/tcp_load_test.cr -o bin/karma_tcp_load_test
bin/karma_tcp_load_test \
  --clients=4 \
  --wal=true \
  --wal-fsync=false
```

Тест зависимости от объема данных:

```sh
crystal build --release scripts/volume_load_test.cr -o bin/karma_volume_load_test
bin/karma_volume_load_test \
  --sizes=10000,50000,100000 \
  --bucket-count=7 \
  --batch-size=1000 \
  --single-rounds=1000 \
  --read-rounds=100
```

Тест репликации master/slave:

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

Сверка CSV против экспортированных агрегатов:

```sh
crystal run scripts/reconcile_csv.cr -- \
  --host=127.0.0.1 \
  --port=8080 \
  --series=links \
  --csv=clickhouse-links.csv \
  --report
```

## Сигналы

* `SIGINT`: перестать принимать новых TCP-клиентов, сделать dump всех series,
  очистить WAL после успешных снимков состояния и выйти со статусом 0.
* `SIGUSR1`: сделать dump всех series, очистить WAL после успешных снимков
  состояния и продолжить работу.

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

Библиотека `counter_tree` лежит в `lib/counter_tree`, поэтому часть хранилища
можно разрабатывать и тестировать прямо внутри этого репозитория.

## Лицензия

MIT
