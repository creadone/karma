# Runbook репликации Karma

## Область применения

Текущая production-модель репликации:

```text
single master -> async polling slaves
```

Slave является read-only node. Он получает snapshot с master, выставляет
`karma.replication.lsn` в `last_lsn` snapshot-а и дальше догоняет WAL через
`replication.entries`.

В этой версии нет automatic leader election, quorum и защиты от split-brain.
Failover только ручной.

## Rebuild slave

Использовать, когда нужен новый slave или существующий slave отстал/поврежден.

1. Остановить slave.

2. Сохранить старую директорию данных для диагностики:

   ```sh
   mv /var/lib/karma-slave /var/lib/karma-slave.broken-$(date +%Y%m%d%H%M%S)
   mkdir -p /var/lib/karma-slave
   ```

3. Запустить slave с source master:

   ```sh
   bin/karma \
     --role=slave \
     --port=8081 \
     --directory=/var/lib/karma-slave \
     --restore=true \
     --replication-source-host=127.0.0.1 \
     --replication-source-port=8080 \
     --replication-token=read-secret \
     --replication-poll-interval-ms=100 \
     --replication-batch-size=1000
   ```

4. Проверить bootstrap:

   ```json
   {"v":2,"op":"replication.status"}
   ```

   Ожидаем:

   - `role == "slave"`;
   - `replication_bootstrap_error_count == 0`;
   - `replication_poll_error_count == 0`;
   - `replayed_lsn` растет до `wal_current_lsn` master-а;
   - `replication_lag_entries` возвращается к 0 или к малому рабочему уровню.

5. После догоняния вернуть read traffic на slave.

## Manual failover

Использовать только при подтвержденной потере master-а.

1. Зафиксировать, что старый master больше не принимает writes.

   Важно: старый master нельзя вернуть как master без reseed, иначе возможен
   split-brain.

2. Выбрать slave с минимальным lag:

   ```json
   {"v":2,"op":"replication.status"}
   ```

   Лучший кандидат:

   - `replication_lag_entries == 0`;
   - `replication_poll_error_count` не растет;
   - `replication_last_received_unix` свежий;
   - `replayed_lsn` максимальный среди slave-ов.

3. Остановить выбранный slave.

4. Запустить его как master на новой роли:

   ```sh
   bin/karma \
     --role=master \
     --port=8080 \
     --directory=/var/lib/karma-promoted \
     --restore=true
   ```

5. Переключить writers на новый master.

6. Остальные slave-ы перестроить от нового master-а через rebuild slave.

7. Старый master, если он вернулся, запускать только как новый slave после
   очистки или переноса старой директории данных.

## Alerts

Первые практичные alert-условия:

- `karma_replication_lag_entries > 0` дольше 60 секунд для slave-а, который
  должен быть near-real-time.
- `karma_replication_lag_entries > 10000` в любой момент.
- Рост `karma_replication_poll_errors_total` за последние 5 минут.
- `karma_replication_last_poll_success_unix` старше 60 секунд при живом master.
- Рост `karma_replication_bootstrap_errors_total`.
- `karma_replication_last_received_unix` старше 60 секунд при ненулевом write
  traffic на master.
- `karma_wal_current_lsn - karma_replication_replayed_lsn` не уменьшается после
  окончания write burst.

Порог `10000` entries зависит от размера batch WAL entries. Для production его
нужно откалибровать по локальному `scripts/replication_load_test.cr` и реальному
write profile.

`replication.entries` ограничен не только количеством WAL entries, но и byte
budget-ом от `max_response_bytes`. Если page обрезан по размеру, master вернет
`truncated_by_bytes: true`; slave продолжит со следующего `next_lsn` на
следующем poll-е.

## Диагностика

Минимальный набор команд:

```json
{"v":2,"op":"system.health"}
{"v":2,"op":"system.stats"}
{"v":2,"op":"system.metrics"}
{"v":2,"op":"replication.status"}
{"v":2,"op":"snapshot.info"}
{"v":2,"op":"snapshot.verify"}
```

Что смотреть:

- `wal_current_lsn` на master;
- `replayed_lsn` на slave;
- `replication_lag_entries`;
- `replication_poll_error_count`;
- `replication_last_poll_error`;
- `replication_bootstrap_error_count`;
- `last_snapshot_lsn`;
- свежесть snapshot metadata.
- результат `snapshot.verify`: он проверяет sidecar metadata, непрерывность WAL
  LSN, границу snapshot/WAL и `karma.wal.lsn`.

## Локальный master+slave load test

Сначала собрать бинарь:

```sh
shards build --release
```

Запуск smoke-теста:

```sh
crystal run scripts/replication_load_test.cr -- \
  --binary=bin/karma \
  --keys=1000 \
  --batch-size=100 \
  --write-batches=20 \
  --read-rounds=20
```

Более близкий к рабочему профиль:

```sh
crystal build --release scripts/replication_load_test.cr -o bin/karma_replication_load_test
bin/karma_replication_load_test \
  --binary=bin/karma \
  --clients=4 \
  --keys=10000 \
  --batch-size=1000 \
  --write-batches=100 \
  --read-rounds=100 \
  --replication-poll-interval-ms=10 \
  --replication-batch-size=1000
```

Чтобы проверить дробление `replication.entries` по размеру response, можно
добавить `--max-response-bytes=524288`.

Тест поднимает два процесса:

- master принимает `series.batch_add`;
- slave bootstrap-ится через snapshot;
- slave читает через `counter.batch_sum`;
- в конце проверяется, что `master_total == slave_total` и lag дошел до 0.
