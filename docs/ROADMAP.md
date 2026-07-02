# Роадмап

MVP включает четыре продуктовых блока (решение от 2026-07-02): **ошибки+issues, sourcemaps+releases, алерты, tracing**. Блоки идут последовательными вехами M1–M4 — каждая веха самостоятельно полезна и выпускается. Даты не фиксируем — фиксируем порядок и критерии готовности.

## M0 — Фундамент

Скелет и решения, блокирующие всё остальное.

- [x] git-репозиторий, лицензия — **Apache-2.0** (решено 2026-07-02; позиционирование против FSL Sentry).
- [x] Phoenix-приложение `server/` (API-only, Elixir 1.20/OTP 29; `mix test` зелёный), React SPA `web/` (Vite + TS + Bun; build и lint зелёные).
- [x] `compose.yaml` (dev): postgres + clickhouse + redis, healthchecks; prod-профиль с контейнером `swatter` — когда появится релизный образ.
- [x] CI (GitHub Actions): server (format, compile -W, test), web (lint, build). Conformance-заготовка — в M1.
- [x] CLAUDE.md с реальными командами.
- [x] Приняты [ADR-0005](adr/0005-ingest-queue.md) (Redis Streams; спайк: 150k+ XADD/s, 330k событий/с доставки), [ADR-0006](adr/0006-event-grouping.md) (группировка), [ADR-0007](adr/0007-dashboard-auth.md) (auth), [ADR-0008](adr/0008-dashboard-api.md) (API-контракт) — 2026-07-02.

**Готово, когда:** `docker compose up` поднимает пустую систему; CI зелёный; ADR 0005–0008 приняты. → **M0 закрыт 2026-07-02.**

## M1 — Ошибки + issues (ядро) — в работе

- [x] **Срез 1 (2026-07-02), ingest `/envelope/`:** DSN-auth (заголовок `X-Sentry-Auth` и `?sentry_key=`), gzip/deflate с защитой от decompression-бомб, лимиты размеров, CORS для браузерных SDK, envelope целиком в Redis Stream; модель organizations/projects/project_keys; сиды с dev-DSN. Проверено официальным `@sentry/bun` (session + event envelope приняты).
- [x] **Срез 6 (2026-07-02), серверный остаток:** rate limiting per-key по [ADR-0009](adr/0009-rate-limiting.md) (fixed window в Redis, `429` + `Retry-After` + `X-Sentry-Rate-Limits`, fail-open, проверка до чтения тела, per-key переопределение лимитов) и legacy `/store/` (голое событие упаковывается в envelope, общий пролог и общий лимит с `/envelope/`).
- [x] **Срез 2 (2026-07-02), pipeline (Broadway):** consumer group поверх Redis Stream (backlog не теряется), разбор items (неизвестные типы отбрасываются молча), нормализация, fingerprint v1 (ADR-0006), upsert issues в PG (счётчики, reopen resolved), события в CH батчами (TTL 90 дней до ADR-0010); «ядовитые» envelope дропаются с логом, инфраструктурные сбои — redelivery до 5 попыток. Conformance-тест теперь проверяет полный путь: SDK → HTTP → буфер → issue в PG + строка в CH.
- [x] **Срез 3 (2026-07-02), dashboard API (ADR-0008):** REST `/api/0/` в стиле Sentry — организации, проекты (с DSN), issues (фильтр по статусу, сортировки date/new/freq, keyset-пагинация `Link`-заголовком), деталка, resolve/ignore, события issue из CH (список + latest со стектрейсом из payload); OpenAPI-спека из кода (`/api/0/openapi.json` + `server/priv/openapi.json`), генерация TS-типов в `web/src/api/` и типизированный клиент; CI проверяет свежесть спеки и типов.
- [x] **Срез 4 (2026-07-02), auth (ADR-0007):** users/memberships (owner/admin/member), первый запуск без SMTP (`GET/POST /api/0/auth/setup`), login/logout/me, cookie-сессии с ревокацией (токены хэшированы в БД), pbkdf2 (поправка в ADR), весь `/api/0/` под аутентификацией, изоляция организаций (чужое = 404), `mix swatter.reset_password`. API-токены `swt_*` — в M2 вместе с sentry-cli (ADR-0012).
- [x] **Срез 5 (2026-07-02), UI:** React SPA на типизированном клиенте — онбординг (setup первого owner-а), логин/логаут, создание проекта, список issues (статус-табы, сортировки date/new/freq, «Load more» по курсору, empty state с DSN-сниппетом), деталка со стектрейсом (in-app подсветка, контекст кода), тегами, breadcrumbs и resolve/ignore/reopen. Dev: `bun dev` + Vite-прокси `/api` → Phoenix. Проверено живым браузером на реальных данных.
- [x] **Срез 7 (2026-07-02), управление проектами:** страница Projects — именованные проекты как раздельные счётчики (unresolved issues из PG + события за 24ч из CH, по одному группирующему запросу на хранилище), DSN с копированием, inline-переименование (`PUT /api/0/projects/{org}/{proj}`, slug неизменяем, зарезервированные slug'и отклоняются), переключатель проектов на странице issues, ссылка Projects в шапке.
- [x] **Срез 8 (2026-07-02), деплой (ADR-0004):** multi-stage `Dockerfile` (SPA через bun → mix release → slim-runtime без apt), Phoenix отдаёт собранную SPA (`Plug.Static` + catch-all фолбэк) и API из одного контейнера, `/health` liveness, `Swatter.Release.migrate/0` — автомиграции PG+CH на старте; `docker-compose.prod.yaml` из 4 контейнеров с magic-переменными Coolify (`SERVICE_FQDN_*`, `SERVICE_PASSWORD_*`) и фолбэками; [docs/DEPLOY.md](DEPLOY.md). **Проверено холодным стартом на чистых volume**: миграции → setup owner → создание проекта → событие реальным `@sentry/bun` → issue в API; **Linux-бенчмарк из docker-сети: ~17 900 событий/с приёма**, пайплайн разгребает буфер быстрее (см. [BENCHMARKS.md](BENCHMARKS.md)).
- [x] **Срез 9 (2026-07-02), UI-достройка:** поиск по issues (ILIKE title/culprit, debounce, в URL), фильтры по environment/release (значения из CH, `GET .../filters`; сам фильтр — issue_id из CH → выборка из PG), история вхождений в деталке (список событий issue из CH с курсором, клик переключает показываемый стектрейс). Проверено живым браузером.
- [x] **Conformance-матрица (ключевой артефакт вехи, срез 10):** [x] Bun · [x] Python · [x] Go · [x] Rust · [x] Elixir · [x] Node.js (настоящий node) · [x] Erlang (официального SDK нет — тонкий HTTP-клиент на httpc+json, ADR-0001) — все семь проходят полный путь до issue в PG (`mix test --only conformance`); [x] C++ (sentry-native: CMakeLists+main готовы, тест opt-in `SWATTER_CPP_CONFORMANCE=1` из-за тяжёлой сборки cmake+libcurl — оставлен на ручной/Linux-прогон). Матрица поймала два расхождения форм протокола: `exception` голым списком (sentry-go) и `message` объектом (sentry-elixir).
- [x] Бенчмарк ingest — первичный, см. [BENCHMARKS.md](BENCHMARKS.md): на Windows-dev замер упирается в loopback-артефакт (54 мс даже на no-op), сервер и пайплайн без ошибок и без backlog; честный потолок — повторить на Linux при деплой-срезе.

**Готово, когда:** реальное приложение с официальным Sentry SDK переезжает на Swatter заменой DSN и работает. → **M1 закрыт 2026-07-02:** приём (envelope + store, rate limiting) → пайплайн → issues (PG) + события (CH) → dashboard API под auth → React UI (онбординг, issues с поиском/фильтрами/историей, проекты); 7 платформ conformance; self-hosted-деплой одной командой (~18k событий/с). C++ в матрице и Linux-профилирование пайплайна — вне критического пути.

## M2 — Releases + sourcemaps

- [x] **Срез 1 (2026-07-02):** сущность releases (миграция, монотонный `ordinal` в проекте, `Releases.get_or_create` в пайплайне), привязка событий/issues к релизу (`first_release_id`), regression-детект по ADR-0011 (resolved-issue вернулся в релизе новее `resolved_in_release` → reopen + флаг `regressed`), API `/releases` (список со счётчиком new issues + деталка), `regressed` в issue-сериализации.
- [x] **Срез 2 (2026-07-02):** загрузка sourcemap-артефактов (ADR-0012) — `POST /api/0/projects/{org}/{proj}/artifacts` multipart (`file`, `debug_id`, `type`, `name`), идемпотентно по `(project, debug_id, type)`, лимит 30 МБ → 413; хранение gzip-сжатым bytea в PG; `Artifacts.fetch_source_map/2` для символикатора (debug_id матчится без дефисов/регистра). Chunk-upload `sentry-cli` — отдельным срезом позже поверх той же модели.
- [x] **Срез 3 (2026-07-02, ядро M2):** свой Source Map v3 декодер (Base64 VLQ, поиск исходной позиции по generated + контекст из sourcesContent); ETS-кэш разобранных карт по `{project, debug_id}` (загрузка в вызывателе — уважает sandbox); `Swatter.Symbolication` разворачивает минифицированные фреймы по `debug_meta.images[].debug_id` (best-effort, без карты фрейм не теряется), проставляет исходный файл/строку/функцию/контекст и `data.symbolicated`; включён в пайплайн ДО нормализации (ADR-0011: fingerprint по развёрнутому стеку).

- [x] **Срез 4 (2026-07-02), UI:** страница Releases (список релизов со счётчиком new issues + деталка с новыми issues релиза), regression-бейдж на issue в списке/деталке, отметка `source` на символикованных фреймах в деталке issue, ссылка Releases. Проверено живым браузером на реальном end-to-end (загрузка sourcemap → событие с минифицированным фреймом → `src/app.ts:3 handleClick` с исходным контекстом).

**Готово, когда:** ошибка из production-бандла (minified) показывается с исходным кодом и номерами строк. → **достигнуто end-to-end** (осталось автоматизировать conformance реальным бандлом — срез 5).

- [x] **Срез 5 (2026-07-02), conformance реальным бандлом:** esbuild + официальный `@sentry/esbuild-plugin` собирают минифицированный бандл + sourcemap с инжектированным Debug ID; настоящий node с `@sentry/node` шлёт событие с минифицированным стеком и `debug_meta`; тест загружает карту по извлечённому debug_id и проверяет, что фреймы развёрнуты в исходник (`app.js`, контекст с `crashDeepInside`). Декодер проверен на реальном esbuild-выводе. → **M2 закрыт.**

## M3 — Алерты (Telegram) + AI-анализ issues — в работе

- **Канал — только Telegram** (решение 2026-07-02): общий бот на инстанс (`TELEGRAM_BOT_TOKEN`), per-project `chat_id`. Email/Slack/webhook в MVP не делаем.
- **Движок правил (ADR-0013):** новый issue, регрессия, порог частоты (N событий за T по issue); per-project настройки; дедуп/cooldown в Redis; доставка через Oban с ретраями. Oban появляется здесь (предусмотрен ADR-0002), переиспользуется AI-агентом.
- **AI-агент (ADR-0016):** анализ каждого issue на **z.ai GLM** (суть, вероятная причина, `severity`, предложение по фиксу) — авто на новый issue (Oban) + кнопка «Проанализировать» в деталке; результат в деталке issue и в тексте Telegram-алерта. Фича опциональна: нет `ZAI_API_KEY` → выключена.
- **Срезы:** (1) Oban + конфиг + модель настроек алертов; (2) Telegram-доставка + триггер new/regression; (3) правило порога частоты; (4) AI: z.ai-клиент + Oban-воркер + хранение анализа; (5) API + UI (настройки алертов, панель AI + кнопка). Каждый — с живой проверкой.
- Ingest `session(s)` items → crash-free rate — перенесено в пост-MVP (не блокирует алерты).

**Готово, когда:** команда узнаёт о новой ошибке из Telegram (с AI-резюме) раньше, чем из UI; в деталке issue виден AI-разбор.

## M4 — Tracing / performance (закрывает MVP)

- Ingest item `transaction`, схема spans в CH (ADR-0014).
- UI: список транзакций (p50/p95/throughput), trace waterfall, связь error ↔ trace по `trace_id` (из деталки ошибки — в трейс и обратно).
- Сэмплинг — на стороне SDK (traces_sample_rate); динамическое серверное сэмплирование — пост-MVP.

**Готово, когда:** по медленному запросу виден waterfall спанов и связанные ошибки. Это — граница MVP.

## Пост-MVP (кандидаты, порядок не фиксирован)

- Нативная символикация: minidump endpoint, DWARF/PDB, Rust sidecar (ADR-0011) — полноценные C++/Rust крэши.
- Cron-мониторинг (`check_in` items), uptime.
- OTLP-ingest как второй вход; профили; session replay (большой блок).
- SSO/SAML, аудит-лог; мультитенантный SaaS-режим (модель данных уже готова, ADR-0004).
- Дашборды/метрики продукта, Helm-чарт.
