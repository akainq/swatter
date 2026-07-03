# Swatter

Self-hosted error and performance monitoring, **wire-compatible with the Sentry ingest protocol**: existing official Sentry SDKs (Node.js/Bun, Go, Python, C++, Rust, Elixir/Erlang) work with Swatter by changing a single line — the DSN.

**Status: MVP complete.** Errors & issues, source maps & releases, Telegram alerts with on-demand AI issue analysis, and tracing/performance all work end to end, verified by an automated conformance suite against the official Sentry SDKs.

## Why not self-hosted Sentry

Official self-hosted Sentry is ~16 containers including Kafka and ZooKeeper. Swatter is **4 containers** (`swatter` + PostgreSQL + ClickHouse + Redis), installs in about 10 minutes, and there is no lock-in: migrating to Sentry and back is a DSN swap.

## Features

- **Errors & issues** — envelope + legacy store ingest with per-key rate limiting, durable Redis Streams buffer, Broadway processing pipeline, fingerprint-based grouping, issue lifecycle (resolve / ignore / regression detection), search, environment/release filters, occurrence history.
- **Source maps & releases** — Debug ID based symbolication with a built-in Source Map v3 decoder: minified production stack traces are expanded to original files, lines and source context. Releases with new-issue counters and regressions detected by release order.
- **Alerts via Telegram** — per-project rules (new issue, regression, frequency threshold), cooldowns, delivery through background jobs with retries; a single bot token per instance, a chat id per project.
- **AI issue analysis (optional)** — an on-demand summary of the root cause, severity and a suggested fix, produced by an OpenAI-compatible LLM endpoint (z.ai GLM by default). Runs only when a user clicks Analyze; disabled entirely unless an API key is configured.
- **Tracing & performance** — transaction ingest into ClickHouse, p50/p95/throughput per transaction, a cross-service trace waterfall, and errors linked to traces by `trace_id` in both directions.

## Stack

Elixir (Phoenix, Broadway, Oban) · PostgreSQL · ClickHouse · Redis · React (Vite + TypeScript)

## Quick start (dev)

```sh
docker compose up -d --wait        # Postgres :5433, ClickHouse :8123, Redis :6380
cd server && mix deps.get && mix phx.server   # API on localhost:4000
cd web && bun install && bun dev              # SPA on localhost:5173
```

Tests: `cd server && mix test`; frontend: `cd web && bun run lint && bun run build`.

## Deploy (self-hosted)

Four containers; database migrations run automatically on startup. Works as a Coolify Docker Compose resource or with plain `docker compose`:

```sh
export SECRET_KEY_BASE=$(openssl rand -base64 48)
docker compose -f docker-compose.prod.yaml up -d --build   # → http://<host>:4000
```

The first visit offers to create the owner account (no SMTP required); then create a project and point any Sentry SDK at its DSN. Optional integrations are enabled by environment variables: `TELEGRAM_BOT_TOKEN` for alerts, `ZAI_API_KEY` for AI analysis.

## License

[Apache-2.0](LICENSE)
