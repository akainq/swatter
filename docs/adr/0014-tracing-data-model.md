# ADR-0014: Модель данных трейсинга — spans в ClickHouse

- **Статус:** Accepted
- **Дата:** 2026-07-03
- **Вопрос:** как хранить транзакции/спаны для performance-мониторинга (M4) и как связать трейсы с ошибками.

## Контекст

- M4 (ROADMAP): «по медленному запросу виден waterfall спанов и связанные ошибки» — граница MVP.
- Официальные SDK при `tracesSampleRate > 0` шлют envelope-items типа `transaction` (ADR-0001): event-подобный JSON с `contexts.trace` (trace_id/span_id/op/status), `start_timestamp`/`timestamp` и массивом `spans[]`. Ingest уже принимает такие envelope (неизвестные типы дропались молча — теперь `transaction` обрабатываем).
- SDK сами пропагируют trace-контекст между сервисами (`sentry-trace`/`baggage`) — ошибки уже несут `trace_id` (колонка в `events` с M1). Это же закрывает кросс-сервисную связку ошибок (решение 2026-07-03: отдельный ADR по correlation-ID не нужен).
- Ограничения ADR-0003: ClickHouse — только батч-вставки, никаких JOIN с PG, измерения денормализуются при записи.

## Решение

**Одна таблица `spans`** (span = строка; транзакция = корневой span):

- `is_segment = 1` — корневой span транзакции (segment); его `span_id` продублирован в `segment_id` каждой строки трейса этого сервиса.
- Имя транзакции — `transaction_name` — **денормализовано в каждую строку** (фильтры/группировки без JOIN; имя колонки не `transaction`, чтобы не задевать SQL-парсер).
- Поля: id-шники (`trace_id` FixedString(32), `span_id` FixedString(16), `parent_span_id`), `op`/`description`/`status`, `start_ts`/`end_ts`/`duration_ms`, денормализованные измерения (`environment`, `release`, `platform`, `tags` с промоушеном `server_name` — как у ошибок), `org_id`/`project_id`, `received_at`.
- Движок: MergeTree, `PARTITION BY toYYYYMM(start_ts)`, `ORDER BY (project_id, start_ts)` — под оконные агрегаты; **TTL 30 дней** (спаны на порядок объёмнее ошибок; у ошибок 90 — решение 2026-07-03, пересмотр в ADR-0010).
- **Bloom-filter skip-index по `trace_id`** — waterfall (`WHERE org_id = ? AND trace_id = ?`, кросс-проектный запрос) не сканирует партиции целиком при «чужом» для ORDER BY ключе.

**Агрегаты на лету.** p50/p95/throughput — quantile-функции ClickHouse по корневым строкам (`is_segment = 1`) за окно, без предагрегатов. На self-hosted объёмах это миллисекунды; materialized views — пост-MVP, если упрёмся.

**Ingest/пайплайн.** `transaction`-items разбираются тем же Broadway-пайплайном: `SpanBuilder` превращает транзакцию в пачку строк (валидация hex-id, битые дропаются с логом — «ядовитый» контент не ретраится), батчер делает две `insert_all` (events и spans) из одного батча. Транзакции не создают issues и не триггерят алерты. Rate limiting — общий per-key (ADR-0009).

**Сэмплинг** — на стороне SDK (`traces_sample_rate`); сервер хранит всё, что пришло. Динамическое серверное сэмплирование — пост-MVP.

**Связь error ↔ trace.** По `trace_id`, который уже есть в обеих таблицах: из деталки issue — «View trace» + секция «Related errors» (события с тем же `trace_id` по всем проектам организации — фронт↔бэк↔микросервисы); в waterfall помечены спаны, на которые пришлись ошибки. Bloom-index по `trace_id` добавляется и в `events`.

## Альтернативы

- **Две таблицы (transactions + spans).** Отклонено: два пути вставки/чтения без выгоды на нашем масштабе; агрегатам достаточно фильтра `is_segment = 1`, локальность по `ORDER BY (project_id, start_ts)` сохраняется.
- **Предагрегация (materialized views) для p50/p95.** Отклонено для MVP: усложняет миграции и вставку; quantile по сырым строкам за типовые окна на self-hosted быстро. Точка расширения остаётся.
- **OTLP как формат хранения/приёма.** Отклонено: ingest-совместимость строится вокруг протокола Sentry (ADR-0001); OTLP-ingest — пост-MVP вторым входом.
- **`ORDER BY (org_id, trace_id, …)` под waterfall.** Отклонено: ломает локальность оконных агрегатов (основной запрос); bloom-index решает точечные выборки дешевле.

## Последствия

- (+) Один путь вставки и одна схема на транзакции и спаны; waterfall и агрегаты без JOIN.
- (+) Ошибки и трейсы связываются «бесплатно» — `trace_id` уже пропагируется SDK и хранится.
- (−) Denormalized-строки шире (имя транзакции в каждой) — плата за отсутствие JOIN; смягчается LowCardinality/сжатием CH.
- (−) TTL 30 дней фиксирован до ADR-0010 (retention per-project).
- Риск: кардинальность `transaction_name` (URL с id вместо шаблона) раздувает список транзакций — это поведение SDK; серверная нормализация имён — пост-MVP.
