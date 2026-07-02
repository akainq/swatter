# Архитектура Swatter

Целевая архитектура MVP. Решения и их обоснования — в [ADR](adr/README.md); этот документ — сводная картина.

## Компоненты

Инсталляция — 4 контейнера ([ADR-0004](adr/0004-deployment-self-hosted.md)):

```
                                  ┌──────────────────────────────────────────┐
 Sentry SDK                       │  swatter (Elixir, один релиз)            │
 (@sentry/node, sentry-go,        │                                          │
  sentry-python, sentry-native,   │  ┌─────────┐   ┌──────────┐  ┌────────┐  │
  sentry (Rust), sentry-elixir…)  │  │ Ingest  │──▶│ Pipeline │─▶│ Alerts │──┼─▶ email/Slack/webhook
            │                     │  │ (Plug)  │   │(Broadway)│  └────────┘  │
            │  POST /api/{id}/    │  └────┬────┘   └─┬──────┬─┘              │
            └──── envelope/ ─────▶│       │          │      │   ┌─────────┐  │
                                  │       ▼          ▼      ▼   │ Web API │◀─┼── React SPA
                                  │   [буфер: Redis Streams]│   │(Phoenix)│  │   (dashboard)
                                  └───────┼──────────┼──────┼───┴────┬────┴──┘
                                          │          │      │        │
                                       ┌──▼───┐  ┌───▼────┐ └──┬─────┘
                                       │Redis │  │ Click  │ ┌──▼───────┐
                                       │      │  │ House  │ │ Postgres │
                                       └──────┘  └────────┘ └──────────┘
```

- **Ingest** — тонкий HTTP-приём Sentry-протокола ([ADR-0001](adr/0001-sentry-ingest-protocol.md)): auth по DSN-ключу (кэш в ETS), rate limit (Redis), лимиты размера, распаковка gzip, минимальная валидация envelope → буфер → `200 {"id": ...}`. Никакой тяжёлой работы в запросе.
- **Pipeline** — Broadway-конвейер: декодирование items → нормализация → обогащение (release, sourcemaps с M2) → группировка (fingerprint) → upsert issue в PG → батч-вставка в CH → триггеры алертов.
- **Web API** — Phoenix: REST JSON (OpenAPI-контракт, ADR-0008) + SSE для live-обновлений; отдаёт собранную React SPA статикой.
- **Alerts** — оценка правил на потоке (new issue / regression / частота), доставка через Oban с ретраями, дедупликация в Redis.

## Поток события

1. SDK шлёт `POST /api/{project_id}/envelope/` (gzip, `X-Sentry-Auth: ... sentry_key=...`).
2. Ingest: ключ→проект (ETS-кэш) → rate limit / квота → лимит размера → `XADD` в Redis Stream → `200`. Отказ по лимитам: `429` + `Retry-After` (+ `X-Sentry-Rate-Limits`) — официальные SDK корректно ретраят и буферизуют.
3. Broadway-консьюмер (consumer group): парсинг envelope на items; неизвестные типы отбрасываются молча (forward compat).
4. Для `event`: нормализация схемы → коррекция времени по `sent_at` → (M2: разворачивание stacktrace через sourcemaps по Debug ID) → fingerprint (ADR-0006) → issue upsert в PG (батчами, счётчики `times_seen`/`last_seen` инкрементально) → вставка строки в буфер CH-батчера.
5. CH-батчер: вставка пачками (N событий или T мс — что раньше) в `events`.
6. Alerts: события, породившие новый issue или регрессию, попадают в оценку правил; уведомления — задачи Oban.
7. `client_report` items учитываются в метриках потерь на стороне SDK; `session(s)` — в агрегаты crash-free.

## Модель данных (набросок)

**PostgreSQL** (control plane, Ecto-миграции):
`organizations`, `projects`, `project_keys` (public_key, rate-limit конфиг), `users`, `memberships`, `issues` (project_id, fingerprint_hash UNIQUE per project, title, culprit, level, status: unresolved/resolved/ignored, assignee, first_seen, last_seen, times_seen, first_release, last_release), `releases`, `artifact_bundles` (sourcemaps, debug_id), `alert_rules`, `notification_channels`, `api_tokens`.

**ClickHouse** (миграции — версионированные SQL-файлы):

- `events` — MergeTree `ORDER BY (project_id, issue_id, timestamp)`, TTL по retention. Колонки: идентификаторы (org/project/issue/event_id, trace_id), timestamp, level, message, exception (тип, значение, стектрейс — JSON String), `tags Map(String,String)`, user-поля, release, environment, sdk, контексты.
- `transactions` и `spans` (M4) — `ORDER BY (project_id, timestamp)` / `(project_id, trace_id)`; схема — ADR-0014.
- `sessions` — предагрегированные счётчики для crash-free rate.

Правила: JOIN PG↔CH нет — измерения денормализуются в CH при записи; вставки только батчами из пайплайна ([ADR-0003](adr/0003-storage-postgres-clickhouse.md)).

## Группировка (v1, до ADR-0006)

Приоритет: явный `fingerprint` из события → хэш по стектрейсу исключения (нормализованные in-app фреймы: module+function, без номеров строк) + тип исключения → шаблонизированный `message`. SHA-256 → `issues.fingerprint_hash`.

## Символикация

- **JS sourcemaps (M2)**: на BEAM — sourcemap это JSON; резолв по Debug ID из `artifact_bundles`, кэш разобранных карт.
- **Нативная (C++/Rust minidumps, DWARF) — пост-MVP**: не на BEAM; Rust sidecar или NIF — ADR-0011 (там же вопрос лицензии sentry/symbolicator).

## Масштабирование (документированный путь, не MVP)

Вертикально — основной путь. Дальше: BEAM-кластер (libcluster; ingest и pipeline — те же ноды), CH — отдельная машина, Redis Streams → Kafka за Broadway-абстракцией (новый ADR). Потолок одной ноды уточняется бенчмарком в M1.

## Самомониторинг

Swatter репортит собственные ошибки через sentry-elixir в себя же (отдельный внутренний проект) + во внешний контур при наличии (ADR-0015).
