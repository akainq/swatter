# Деплой

Инсталляция Swatter — **4 контейнера** (ADR-0004): `swatter` (релиз Elixir,
отдаёт и API, и SPA), PostgreSQL, ClickHouse, Redis. Всё описано в
[docker-compose.prod.yaml](../docker-compose.prod.yaml); миграции обеих БД
выполняются автоматически при старте контейнера приложения.

## Вариант A: Coolify

1. **Resources → New → Docker Compose**, источник — этот git-репозиторий,
   файл — `docker-compose.prod.yaml`.
2. Coolify сам заполнит магические переменные из compose:
   - `SERVICE_FQDN_SWATTER_4000` — назначьте приложению домен в UI Coolify;
     он же попадает в `PHX_HOST` (правильные ссылки и куки);
   - `SERVICE_BASE64_64_SECRETKEYBASE` → `SECRET_KEY_BASE`;
   - `SERVICE_PASSWORD_POSTGRES`, `SERVICE_PASSWORD_CLICKHOUSE` — пароли БД.
3. Deploy. TLS-терминация — на прокси Coolify; приложение понимает
   `X-Forwarded-Proto` (`force_ssl` с `rewrite_on`).
4. Откройте домен: первый запуск предложит создать owner-аккаунт
   (SMTP не нужен), дальше — создание проекта и готовый DSN.

Замечания:

- Публикация порта `4000` в compose нужна только для ручного запуска;
  в Coolify маршрутизацию делает его прокси (переопределите
  `SWATTER_HTTP_PORT`, если порт конфликтует, или уберите публикацию).
- Проверьте в **Environment Variables** ресурса, что
  `SERVICE_BASE64_64_SECRETKEYBASE` реально заполнена (≥64 символов).
  Магические переменные Coolify иногда остаются пустыми — тогда задайте
  `SECRET_KEY_BASE` руками (`openssl rand -base64 48`): явное значение
  имеет приоритет. С пустым/коротким секретом релиз падает на старте
  с понятной ошибкой (см. «Диагностика»).
- Обновление: redeploy в Coolify; миграции additive-only и выполняются
  на старте новой версии (ADR-0004).

## Вариант B: голый docker compose

```sh
export SECRET_KEY_BASE=$(openssl rand -base64 48)
# опционально: PHX_HOST=errors.example.com, пароли БД
docker compose -f docker-compose.prod.yaml up -d --build
```

Приложение — на `http://<host>:4000` (или `SWATTER_HTTP_PORT`). За TLS в
этом варианте отвечает ваш reverse-proxy (Caddy/Traefik/nginx) —
пробрасывайте `X-Forwarded-Proto` и задайте `PHX_HOST`.

Дефолтные пароли БД (`swatter`/`swatter`) допустимы только когда порты БД
не опубликованы наружу (в поставляемом compose они не публикуются);
для продакшена задайте `SERVICE_PASSWORD_POSTGRES`/`SERVICE_PASSWORD_CLICKHOUSE`.

## Переменные приложения

| Переменная | Обязательна | Что делает |
|---|---|---|
| `SECRET_KEY_BASE` | да (вне Coolify) | подпись cookie-сессий; ≥64 байта (`mix phx.gen.secret`) |
| `DATABASE_URL` | да | `ecto://user:pass@host:5432/db` (PostgreSQL) |
| `CLICKHOUSE_URL` | да | `http://user:pass@host:8123/db` |
| `REDIS_URL` | да | `redis://host:6379` |
| `PHX_HOST` | да | внешний домен (ссылки, куки, force_ssl) |
| `PORT` | нет (4000) | HTTP-порт приложения |
| `POOL_SIZE` | нет (10) | пул PostgreSQL |
| `TELEGRAM_BOT_TOKEN` | нет | Telegram-алерты (ADR-0013): токен бота, общий на инстанс; без него алерты выключены. `chat_id` — per-project в UI (Projects → Alerts) |
| `ALERT_COOLDOWN_SECONDS` | нет (900) | cooldown повторных алертов по одному issue |
| `ZAI_API_KEY` | нет | AI-анализ issues (ADR-0016, z.ai): без ключа фича выключена, кнопки в UI нет |
| `ZAI_MODEL` | нет (glm-4.6) | строка модели z.ai |
| `ZAI_BASE_URL` | нет | переопределение эндпоинта z.ai |

## Health и диагностика

- `GET /health` — liveness без auth (его использует healthcheck compose).
- Логи: `docker compose -f docker-compose.prod.yaml logs -f swatter`.
- Сброс пароля админа (ADR-0007, SMTP не нужен):

  ```sh
  docker compose -f docker-compose.prod.yaml exec swatter \
    /app/bin/swatter rpc 'Swatter.Release.reset_password("admin@example.com")'
  ```

## Логин отвечает 500: «cookie store expects conn.secret_key_base to be at least 64 bytes»

В контейнер пришёл пустой или короткий `SECRET_KEY_BASE` (обычно — не
заполнившаяся магическая переменная Coolify `SERVICE_BASE64_64_SECRETKEYBASE`).
Приложение при этом стартует и `/health` зелёный: cookie-store проверяет секрет
только при первой записи сессии, то есть на логине. Начиная с текущей версии
релиз валидирует секрет на старте и падает сразу с этим же объяснением.

Лечение: в Coolify задайте ресурсу переменную `SECRET_KEY_BASE`
(`openssl rand -base64 48`) — она имеет приоритет над магической — и
сделайте Restart/Redeploy. Смена секрета инвалидирует существующие сессии.

## Сборка падает на hex.pm (`:timeout`, «Unknown package … in lockfile»)

Симптом: сетевые шаги docker-сборки, ходящие на `builds.hex.pm` / `repo.hex.pm`
(Fastly), таймаутят (`request timed out`, `Failed to fetch record … :timeout`;
«Unknown package X in lockfile» — следствие недокачанного реестра, lockfile ни
при чём). У некоторых хостингов маршрут до Fastly деградирован, при этом GitHub
работает нормально — характерный признак: git clone в том же билде проходит за
секунды, а hex.pm висит.

Что уже сделано в Dockerfile:

- hex и rebar3 ставятся **из GitHub** (`mix archive.install github hexpm/hex`,
  бинарь rebar3 из releases + `MIX_REBAR3`) — `builds.hex.pm` не используется
  вовсе. Это важно: у загрузок `mix local.hex` / `mix local.rebar` жёсткий
  таймаут 60 с, который не настраивается (`HEX_HTTP_TIMEOUT` на них не влияет).
- `mix deps.get` (единственный оставшийся поход на Fastly, `repo.hex.pm`) идёт
  с `HEX_HTTP_TIMEOUT=300`, `HEX_HTTP_CONCURRENCY=1` и пятью ретраями — медленный
  маршрут он переживает, полностью мёртвый нет.

Если `deps.get` стабильно падает и на таком режиме, проверьте маршрут с хоста:

```sh
docker run --rm elixir:1.20-otp-29 bash -lc \
  'mix archive.install github hexpm/hex tag v2.5.1 --force && time mix hex.package fetch jason 1.4.4 -o /tmp/j.tar'
```

Обходной путь — собрать образ на машине с нормальной сетью и деплоить готовый
образ через registry (в Coolify — ресурс типа «Docker Image» вместо сборки из
репозитория).
