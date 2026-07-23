# Architecture Decision Records (ADR)

Все значимые архитектурные решения фиксируются здесь. Принятое решение меняется только новым ADR со статусом `Supersedes ADR-XXXX` — старый файл не редактируется, ему проставляется `Superseded by ADR-YYYY`.

## Процесс

1. Скопировать [template.md](template.md) в `NNNN-kebab-slug.md` (номер — следующий по порядку, слаг на английском, содержимое на русском).
2. Статус `Proposed` → обсуждение → `Accepted` или `Rejected`.
3. Ссылка на ADR добавляется в таблицу ниже.

## Принятые решения

| ADR | Решение | Статус |
|---|---|---|
| [0001](0001-sentry-ingest-protocol.md) | Совместимость с Sentry на уровне ingest-протокола, свои SDK не пишем | Accepted |
| [0002](0002-backend-runtime-elixir.md) | Backend: Elixir (Phoenix + Broadway), не Bun | Accepted |
| [0003](0003-storage-postgres-clickhouse.md) | Хранилища: PostgreSQL + ClickHouse + Redis | Accepted |
| [0004](0004-deployment-self-hosted.md) | Деплой: self-hosted, один docker-compose | Accepted |
| [0005](0005-ingest-queue.md) | Ingest-буфер: Redis Streams + Broadway (спайк: 150k+ XADD/s) | Accepted |
| [0006](0006-event-grouping.md) | Группировка: fingerprint v1 — тип исключения + in-app фреймы, версионируется | Accepted |
| [0007](0007-dashboard-auth.md) | Auth dashboard: сессии в cookie, роли per-org, API-токены; SSO пост-MVP | Accepted |
| [0008](0008-dashboard-api.md) | Dashboard API: REST в стиле Sentry (`/api/0/`) + OpenAPI + SSE | Accepted |
| [0009](0009-rate-limiting.md) | Rate limiting приёма: fixed window в Redis, per-key, `X-Sentry-Rate-Limits` | Accepted |
| [0011](0011-js-symbolication.md) | JS-символикация: Debug IDs, свой sourcemap-декодер на BEAM, кэш в ETS | Accepted |
| [0012](0012-artifact-upload.md) | Загрузка артефактов: свой multipart endpoint, хранение gzip-bytea в PG; chunk-upload позже | Accepted |
| [0013](0013-alerting-engine.md) | Движок алертов: правила (new/regression/частота), cooldown в Redis, Telegram-доставка через Oban | Accepted |
| [0014](0014-tracing-data-model.md) | Трейсинг: одна таблица spans в CH (is_segment, TTL 30 дней, bloom по trace_id), агрегаты на лету, error↔trace по trace_id | Accepted |
| [0016](0016-ai-issue-analysis.md) | AI-анализ issues на z.ai GLM (суть/причина/severity/фикс), фон через Oban, опционально | Accepted |
| [0017](0017-mcp-server.md) | MCP-сервер `/mcp` для AI-агентов: свой JSON-RPC-обработчик, API-токены `swt_*`, тулы get_issue/list_issues/get_trace/resolve_issue | Accepted |

## Роадмап решений (очередь на проработку)

Порядок соответствует моменту, когда решение блокирует разработку (см. [ROADMAP.md](../ROADMAP.md)).

| ADR | Вопрос | Блокирует | Статус |
|---|---|---|---|
| 0010 | Retention и жизненный цикл данных в ClickHouse (TTL, downsampling) | M1 | — |
| 0015 | Самомониторинг: как Swatter мониторит сам себя (dogfooding + внешний контур) | M3+ | — |
