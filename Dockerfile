# Релизный образ Swatter (ADR-0004): SPA + Elixir-release в одном контейнере.

# --- 1. Сборка SPA -----------------------------------------------------------
FROM oven/bun:1 AS web
WORKDIR /web
COPY web/package.json web/bun.lock ./
RUN bun install --frozen-lockfile
COPY web/ ./
RUN bun run build

# --- 2. Сборка Elixir-релиза -------------------------------------------------
FROM elixir:1.20-otp-29 AS build
ENV MIX_ENV=prod LANG=C.UTF-8
WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

COPY server/mix.exs server/mix.lock ./
RUN mix deps.get --only prod

COPY server/config config
RUN mix deps.compile

COPY server/lib lib
COPY server/priv priv
# собранная SPA отдаётся самим Phoenix (Plug.Static + SPA-фолбэк)
COPY --from=web /web/dist priv/static

RUN mix compile
RUN mix release

# --- 3. Runtime ---------------------------------------------------------------
# Без apt: сборочные сети нередко режут зеркала Debian. База elixir-slim
# уже несёт libssl/ncurses/ca-certificates (ERTS всё равно вложен в релиз);
# для healthcheck кладём busybox (именно glibc-вариант — musl-бинарь
# вроде curlimages/curl на debian не стартует).
FROM busybox:glibc AS busybox

FROM elixir:1.20-otp-29-slim AS app

ENV LANG=C.UTF-8 PHX_SERVER=true PORT=4000
WORKDIR /app

COPY --from=busybox /bin/busybox /usr/local/bin/busybox
COPY docker/entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh && useradd --create-home swatter

COPY --from=build --chown=swatter:swatter /app/_build/prod/rel/swatter ./

USER swatter
EXPOSE 4000

CMD ["/app/entrypoint.sh"]
