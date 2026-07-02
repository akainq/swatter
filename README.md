# Swatter

Self-hosted мониторинг ошибок и производительности, **совместимый с Sentry по протоколу приёма**: существующие официальные Sentry SDK (Node.js/Bun, Go, Python, C++, Rust, Elixir/Erlang) работают со Swatter заменой одной строки — DSN.

**Статус: M0 — фундамент.** Скелеты сервера и фронта подняты, продуктовый код впереди. Проектные документы:

- [Архитектура](docs/ARCHITECTURE.md) — компоненты, поток события, модель данных
- [Роадмап](docs/ROADMAP.md) — вехи M0–M4 и критерии готовности
- [ADR](docs/adr/README.md) — принятые решения и очередь открытых вопросов

## Почему не self-hosted Sentry

Официальный self-hosted Sentry — ~16 контейнеров с Kafka и ZooKeeper. Swatter — 4 контейнера (`swatter` + PostgreSQL + ClickHouse + Redis), цель — установка за ≤10 минут, без lock-in: миграция на Sentry и обратно — замена DSN.

## Стек

Elixir (Phoenix, Broadway, Oban) · PostgreSQL · ClickHouse · Redis · React (Vite + TypeScript)

Почему так — [ADR-0002](docs/adr/0002-backend-runtime-elixir.md) (в т.ч. разбор «Bun vs Elixir») и [ADR-0003](docs/adr/0003-storage-postgres-clickhouse.md).

## Быстрый старт (dev)

```sh
docker compose up -d --wait        # Postgres :5433, ClickHouse :8123, Redis :6380
cd server && mix deps.get && mix phx.server   # API на localhost:4000
cd web && bun install && bun dev              # SPA на localhost:5173
```

Тесты: `cd server && mix test`, фронт: `cd web && bun run lint && bun run build`.

## Деплой (self-hosted)

4 контейнера (`swatter` + PostgreSQL + ClickHouse + Redis), миграции — на старте. Coolify (ресурс Docker Compose) либо голый `docker compose`:

```sh
export SECRET_KEY_BASE=$(openssl rand -base64 48)
docker compose -f docker-compose.prod.yaml up -d --build   # → http://<host>:4000
```

Первый запуск предложит создать owner-аккаунт (SMTP не нужен). Подробно — [docs/DEPLOY.md](docs/DEPLOY.md).

## Лицензия

[Apache-2.0](LICENSE)
