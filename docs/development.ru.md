---
id: karma-development-ru
title: Разработка Karma
doc_type: developer-guide
product: karma
component: core
audience:
  - backend
  - sre
  - ai-agent
status: active
version: 1.0.1
last_reviewed: 2026-06-06
source_of_truth:
  - README.ru.md
  - shard.yml
  - src/
  - spec/
  - clients/ruby/
  - clients/crystal/
security_classification: internal
contains_pii: false
contains_secrets: false
summary: >
  Входная документация для разработчиков Karma. Описывает локальный цикл,
  архитектуру, инварианты протокола v2, правила изменения команд, WAL,
  репликации, клиентов и тестов.
---

# Разработка Karma

Этот документ нужен разработчику, который меняет Karma: сервер, протокол,
хранение, репликацию, тесты или клиенты. Он не заменяет код и спецификации.
Если документ расходится с реализацией, источником истины считается код и
тесты.

Karma сейчас проектируется под один основной сценарий: быстрый учет расхода
лимитов. Остальные применения счетчиков не считаются целевыми при выборе
названий, API и оптимизаций.

## Быстрый вход

Требования:

* Crystal 1.17.1;
* Shards;
* Ruby, если нужно менять Ruby-клиент;
* локальная возможность открыть TCP-порт, если нужно запускать сетевые тесты.

Базовый цикл:

```sh
shards install
crystal spec
shards build --release
```

Запустить сервер локально:

```sh
bin/karma \
  --bind=127.0.0.1 \
  --port=8080 \
  --directory=.karma-data \
  --restore=true \
  --wal=true
```

Проверить запись и чтение расхода лимита:

```sh
printf '{"v":2,"op":"counter.increment","series":"api_requests","key":42,"bucket":20260606,"value":1}\n' \
  | nc 127.0.0.1 8080

printf '{"v":2,"op":"counter.sum","series":"api_requests","key":42}\n' \
  | nc 127.0.0.1 8080
```

Если Crystal пытается писать кэш в недоступный домашний каталог, задайте кэш
внутри репозитория:

```sh
env CRYSTAL_CACHE_DIR=.crystal-cache-spec crystal spec
```

Не коммитьте каталоги `.crystal-cache-*`, `.karma-data`, `.spec_*`, `bin/` и
сгенерированные файлы снимков или WAL.

## Термины домена

В публичной документации и клиентах используйте доменные термины расхода
лимитов.

| Термин | Значение |
| --- | --- |
| Лимит | Именованная группа расхода. В протоколе это поле `series`. |
| Субъект | Объект, для которого считается расход: аккаунт, пользователь, рабочая область или проект. В протоколе это поле `key`. |
| День | День UTC в формате `YYYYMMDD`. В протоколе это поле `bucket`. |
| Расход | Беззнаковое 64-битное значение. В протоколе это поле `value`. |
| Снимок | Файл `.tree` с состоянием одного лимита. |
| WAL | Журнал упреждающей записи `karma.wal` и его сегменты. |
| LSN | Монотонный номер записи WAL. Используется восстановлением и репликацией. |

Внутренняя структура данных называется `Karma::BucketedCounter::Store`.
Историческое слово `tree` осталось во внешнем протоколе v2, метриках и файлах
снимков `.tree`; эти имена меняются только через отдельную миграцию формата. Не
добавляйте новые пользовательские формулировки вокруг `links`, `domains` и
других старых примеров. Для новых примеров используйте `api_requests`,
`emails_sent` или другой лимит расхода.

## Карта репозитория

| Путь | Назначение |
| --- | --- |
| `src/main.cr` | Точка входа CLI. |
| `src/config.cr` | Конфигурация, переменные окружения и валидация параметров запуска. |
| `src/runtime.cr` | Сборка runtime: восстановление, bootstrap ведомого узла, сервер, poller репликации. |
| `src/server.cr`, `src/server/client_session.cr` | TCP-сервер, сессия клиента, чтение строк JSON и запись ответов. |
| `src/command.cr` | Главный pipeline обработки запроса и быстрый путь для горячих команд. |
| `src/commands/` | Парсер v2, валидация, registry и обработчики команд. |
| `src/cluster.cr`, `src/cluster/` | In-memory состояние лимитов поверх `Karma::BucketedCounter::Store`. |
| `src/state.cr` | Синхронизация реестра лимитов, per-series блокировки и эксклюзивные операции. |
| `src/wal/` | Запись, сегментация, LSN, replay и постраничное чтение WAL. |
| `src/backup/` | Снимки состояния, metadata, проверка восстановления. |
| `src/idempotency/` | Идемпотентные записи и committed ingest streams. |
| `src/ingest/` | Потоковая загрузка и режимы `add`, `set`, `replace_series`. |
| `src/replication/` | Bootstrap снимков и polling WAL от ведущего узла. |
| `src/operations/` | Stats, metrics и Prometheus-формат. |
| `src/bucketed_counter.cr`, `src/bucketed_counter/` | Внутренняя структура данных `Karma::BucketedCounter`: ключ -> bucket -> value с кешированным total. |
| `clients/ruby/` | Ruby/Rails-клиент протокола v2. |
| `clients/crystal/` | Crystal-клиент протокола v2 и доменный API расхода лимитов. |
| `scripts/` | Нагрузочные, WAL и вспомогательные проверки. |
| `spec/` | Основные specs сервера и протокола. |

## Модель выполнения запроса

Один клиентский запрос - одна строка JSON с `\n`. Сервер отвечает одной строкой
JSON с envelope v2.

```text
TCP client
  -> ClientSession читает строку
  -> Commands.call проверяет размер и JSON
  -> require_v2_request! требует v=2
  -> fast_path обрабатывает горячие counter.increment/counter.sum без лишнего parse
  -> parse_v2 строит Directive
  -> authenticate проверяет token
  -> validate проверяет форму и ограничения
  -> enforce_role! запрещает записи на slave
  -> apply пишет WAL, выполняет идемпотентность и меняет Cluster
  -> Protocol.success/error возвращает v2 envelope
```

Важные свойства pipeline:

* Karma 1.0 принимает только протокол v2. Не добавляйте поддержку legacy v1.
* Публичный `op` остается строкой вида `counter.increment` или `series.batch_add`.
* Внутренний `Directive#command` может называться короче: `increment`,
  `batch_add`, `tree_info`.
* Мутирующая команда должна попасть в WAL до изменения `Cluster`, если WAL
  включен и команда должна сохраняться.
* Slave отклоняет прямые мутирующие команды клиентов.
* Ошибки возвращаются стабильными `error_code`; новые коды добавляйте только
  если старые коды не описывают ситуацию.

## Горячий путь

`src/command.cr` содержит быстрый путь для:

* `counter.increment` и `series.increment` без идемпотентности, токена и
  `fingerprint`;
* `counter.sum` и `series.sum` без range.

Быстрый путь нужен для основного сценария расхода лимитов, где приложение часто
пишет единичное событие расхода и читает текущий итог.

Правила изменения быстрого пути:

1. Сначала докажите, что команда действительно горячая по нагрузочному профилю.
2. Не обходите проверку роли slave для записей.
3. Не обходите WAL для сохраняемых мутаций.
4. Проверяйте переполнение `UInt64` до изменения данных.
5. Сохраняйте тот же v2 envelope и те же error codes.
6. Добавляйте отдельные specs на fast path и обычный path, если поведение может
   разойтись.

Не переносите в быстрый путь команды с токеном, `idempotency_key`, `fingerprint`
или сложной валидацией без отдельного анализа.

## Синхронизация состояния

Karma хранит все лимиты в памяти в `Cluster`.

Синхронизация устроена так:

* `State.synchronize` - эксклюзивная секция для глобальных операций;
* `State.synchronize_series(series)` - shared-вход плюс lock конкретного
  лимита;
* `State.synchronize_registry` - защита реестра лимитов.

Практические правила:

* Для операции над одним лимитом предпочитайте `synchronize_series`.
* Для создания лимита через быстрый путь используйте registry lock.
* Для snapshot, restore-like и других глобальных операций используйте
  эксклюзивную секцию.
* Не держите глобальную блокировку во время долгого сетевого I/O.

## Как добавить или изменить команду v2

Используйте этот чек-лист для любого нового `op`.

1. Опишите публичную форму команды в README, если команда пользовательская.
2. Добавьте чтение новых полей в `src/commands/request_fields.cr`.
3. Добавьте mapping из `op` в `Directive` в `src/commands/v2_parser.cr`.
4. Добавьте или измените обработчик в `src/commands/<domain>/`.
5. Зарегистрируйте внутреннюю команду в `src/commands/registry.cr`.
6. Отнесите команду к `READ_ONLY_COMMANDS` или `MUTATING_COMMANDS`.
7. Добавьте валидацию в `src/commands/validator.cr` и
   `src/commands/validation_rules.cr`.
8. Для мутаций решите, сохраняется ли команда в WAL и поддерживает ли она
   `idempotency_key`.
9. Если команда доступна на slave, проверьте, что это действительно read-only.
10. Добавьте specs в `spec/command_spec.cr` или отдельный spec рядом с
    затронутой областью.
11. Обновите Ruby- и Crystal-клиенты, если команда нужна приложению.
12. Обновите документацию и примеры.

Не добавляйте альтернативные поля без необходимости. В публичном v2 API
предпочитайте `series`, даже если внутри старые структуры называются `tree`.

## WAL и восстановление

WAL находится в `src/wal/`. Запись идет через отдельный writer с batching:

```text
Commands.apply
  -> Wal.append(directive)
  -> append_channel
  -> append_writer_loop
  -> append_group_locked
  -> serialize(directive, lsn)
  -> flush/fsync
  -> update current_lsn
```

Инварианты WAL:

* каждая persisted-запись получает монотонный LSN;
* WAL-запись хранится как v2 envelope с `lsn` и `entry`;
* при `--wal-fsync=true` flush сопровождается fsync;
* при ротации сегмент получает имя `karma.wal.<first_lsn>.segment`;
* sidecar-index сегмента ускоряет чтение страниц для репликации;
* `karma.wal.lsn` хранит текущий LSN;
* replay применяется после загрузки последних снимков.

При изменении WAL обязательно проверьте:

```sh
crystal spec spec/wal_spec.cr
crystal spec spec/dump_spec.cr
crystal spec spec/recovery_spec.cr
crystal spec spec/replication_spec.cr
```

Если меняется формат записи, добавьте migration-план. Для Karma 1.0 не
возвращайте legacy WAL и legacy protocol.

## Идемпотентность

Идемпотентность нужна для at-least-once producers: повтор события расхода не
должен увеличивать лимит второй раз.

Поддерживаемые команды перечислены в `Idempotency.eligible?`:

* `increment`;
* `decrement`;
* `batch_add`;
* `batch_set`;
* `reset`;
* `batch_reset`;
* `delete`;
* `batch_delete_range`.

Правила:

* `idempotency_key` должен быть стабильным и происходить из события-источника
  или job id.
* Пустые ключи запрещены.
* Повтор с тем же fingerprint возвращает сохраненный ответ.
* Повтор с другим fingerprint возвращает `idempotency_conflict`.
* Для новой идемпотентной команды сначала добавьте deterministic fingerprint.
* Ответ идемпотентной команды должен сериализоваться в `JSON::Any`.

Specs по идемпотентности находятся в `spec/idempotency_spec.cr`.

## Потоковая загрузка

Потоковая загрузка нужна для перестроения или импорта расхода лимитов большими
пачками.

Режимы:

| Режим | Когда использовать |
| --- | --- |
| `add` | Добавить агрегированный расход к текущему лимиту. |
| `set` | Установить точные значения по дням. |
| `replace_series` | Собрать временный лимит и атомарно заменить текущий при commit. |

Поток имеет `stream_id`, последовательные `chunk_seq` и fingerprint-и частей.
Повтор уже принятой части пропускается, часть с другим payload получает
`idempotency_conflict`. `replace_series` после commit запоминается через
committed stream, поэтому повтор после восстановления не заменяет лимит второй
раз.

При изменении ingest запускайте:

```sh
crystal spec spec/command_spec.cr
crystal spec spec/idempotency_spec.cr
crystal spec spec/replication_spec.cr
```

## Репликация

Текущая модель:

```text
master -> async polling slave
```

Slave сначала может скачать снимки master-а, затем читает WAL через
`replication.entries`. В проекте нет automatic leader election, quorum и
multi-master. Failover выполняется вручную.

Основные файлы:

* `src/replication/snapshot_client.cr` - bootstrap снимков;
* `src/replication/poller.cr` - периодическое чтение WAL;
* `src/commands/system/replication_entries.cr` - выдача страниц WAL;
* `docs/replication-operations-runbook.md` - эксплуатационный runbook.

При изменении репликации проверяйте и корректность данных, и размер ответа:

```sh
crystal spec spec/replication_spec.cr
crystal build --release scripts/replication_load_test.cr -o bin/karma_replication_load_test
bin/karma_replication_load_test --binary=bin/karma
```

Если меняется `replication.entries`, учитывайте `max_response_bytes` и поле
`truncated_by_bytes`.

## Клиенты

Поддерживаются два клиента:

* `clients/ruby/` - Ruby/Rails-клиент;
* `clients/crystal/` - Crystal-клиент.

Crystal-клиент уже содержит доменные методы для расхода лимитов:

* `record_usage`;
* `set_usage`;
* `record_usage_batch`;
* `usage`;
* `batch_usage`.

Ruby-клиент сейчас предоставляет низкоуровневые методы протокола:
`create_series`, `increment`, `sum`, `batch_add`, `batch_set`, `request` и
`call`. Они рабочие, но новые продуктовые примеры должны использовать лимиты
вроде `api_requests` и `emails_sent`, а не старые `links`/`domains`. Если Ruby
API расширяется, предпочтительны доменные методы на языке расхода лимитов.

При изменении протокола:

1. Обновите Ruby-клиент и его README.
2. Обновите Crystal-клиент и его README.
3. Добавьте тесты на payload, error mapping, idempotency и timeouts, если они
   затронуты.
4. Не добавляйте автоматические retry для мутирующих команд. Для retry нужен
   стабильный `idempotency_key`.

Проверки клиентов:

```sh
ruby clients/ruby/test/karma_client_test.rb
crystal spec clients/crystal/spec
```

Сетевые specs Crystal-клиента поднимают локальный TCP-сервер. В ограниченной
песочнице им может понадобиться разрешение на bind `127.0.0.1:0`.

## Тесты

Основной набор:

```sh
crystal spec
```

Точечные наборы:

```sh
crystal spec spec/command_spec.cr
crystal spec spec/wal_spec.cr
crystal spec spec/replication_spec.cr
crystal spec spec/idempotency_spec.cr
crystal spec spec/bucketed_counter
crystal spec clients/crystal/spec
ruby clients/ruby/test/karma_client_test.rb
```

Форматирование:

```sh
crystal tool format --check src spec scripts clients/crystal/src clients/crystal/spec
```

Перед изменением горячего пути, WAL, сериализации или блокировок сначала
запустите полный `crystal spec`, а затем релевантный нагрузочный тест.

## Нагрузочные проверки

Скрипты в `scripts/` не являются универсальным обещанием эталонной
производительности. Они нужны для локального сравнения "было против стало" на
одном железе и одной версии Crystal.

Внутрипроцессная проверка команд:

```sh
crystal build --release scripts/load_test.cr -o bin/karma_load_test
bin/karma_load_test --series=api_requests --bucket=20260606
```

TCP-профиль:

```sh
crystal build --release scripts/tcp_load_test.cr -o bin/karma_tcp_load_test
bin/karma_tcp_load_test \
  --clients=4 \
  --wal=true \
  --wal-fsync=false \
  --series=api_requests \
  --bucket=20260606
```

WAL paging и sidecar-index:

```sh
crystal build --release scripts/wal_page_bench.cr -o bin/karma_wal_page_bench
bin/karma_wal_page_bench --entries=1000000 --segment-bytes=1048576
```

Репликация:

```sh
crystal build --release scripts/replication_load_test.cr -o bin/karma_replication_load_test
bin/karma_replication_load_test --binary=bin/karma
```

При публикации результатов указывайте:

* дату;
* процессор и среду запуска;
* Crystal version;
* параметры скрипта;
* WAL и fsync режим;
* p95 latency и throughput;
* базовую версию для сравнения.

## Документация

Документы проекта:

* `README.md` - английская входная страница;
* `README.ru.md` - русская входная страница;
* `docs/development.ru.md` - этот документ;
* `docs/replication-operations-runbook.md` - эксплуатация репликации;
* `clients/ruby/README.md` и `clients/crystal/README.md` - клиентские API.

Когда меняется публичное поведение, обновляйте документы в том же изменении,
что и код. Особенно это касается:

* новых или измененных `op`;
* error codes;
* параметров запуска и переменных окружения;
* формата WAL или снимков;
* порядка восстановления;
* семантики идемпотентности;
* клиентских методов.

Не описывайте неподдерживаемые сценарии как равноправные. Для Karma 1.0
основной сценарий - расход лимитов.

## Релизный чек-лист

Перед релизом:

1. Обновите `src/version.cr`.
2. Обновите `shard.yml`.
3. Если менялся Ruby-клиент, обновите `clients/ruby/lib/karma_client/version.rb`
   и gemspec.
4. Если менялся Crystal-клиент, обновите
   `clients/crystal/src/karma_client/version.cr` и `clients/crystal/shard.yml`.
5. Проверьте README и клиентские README.
6. Запустите полный `crystal spec`.
7. Запустите тесты клиентов.
8. Запустите релевантные нагрузочные проверки.
9. Зафиксируйте результаты "было против стало", если менялась
   производительность.

Не меняйте номера версий без понятной причины. Если изменился только текст,
версию можно не поднимать.

## Что не делать

* Не возвращайте устаревший протокол.
* Не добавляйте новую публичную команду без spec-тестов и документации.
* Не пишите в `Cluster` до успешной записи WAL для сохраняемой мутации.
* Не добавляйте повторные попытки мутирующих команд в клиенты без
  идемпотентности.
* Не используйте production-токены, реальные персональные данные и реальные
  идентификаторы клиентов в тестах или документации.
* Не оптимизируйте общий случай в ущерб основному сценарию расхода лимитов без
  измерений.
* Не оставляйте новые `.spec_*`, `.crystal-cache-*`, `bin/` и временные
  каталоги в изменениях.
