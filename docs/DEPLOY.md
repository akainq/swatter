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

## Сборка падает на hex.pm (`:timeout`, «Unknown package … in lockfile»)

Симптом: `mix local.hex` или `mix deps.get` в docker-сборке висят ~15 с на запрос и
падают (`Failed to fetch record … :timeout`; «Unknown package X in lockfile» — следствие
недокачанного реестра, lockfile ни при чём). Сам Dockerfile уже ретраит эти шаги и
поднимает `HEX_HTTP_TIMEOUT`, так что редкие флапы сборку не роняют. Если падает стабильно —
у хоста нестабильный маршрут до hex.pm (Fastly), чаще всего битый IPv6 (адрес есть,
маршрута нет → каждый запрос ждёт таймаут IPv6 перед фолбэком на IPv4):

```sh
# диагностика
ip -6 addr show scope global; ip -6 route show default
docker run --rm elixir:1.20-otp-29 bash -lc 'time mix local.hex --force'

# лечение: отключить IPv6 и перезапустить docker
printf 'net.ipv6.conf.all.disable_ipv6=1\nnet.ipv6.conf.default.disable_ipv6=1\n' \
  | sudo tee /etc/sysctl.d/99-disable-ipv6.conf
sudo sysctl --system && sudo systemctl restart docker
```
