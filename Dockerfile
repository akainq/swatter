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
# builds.hex.pm / repo.hex.pm (Fastly) из некоторых сетей стабильно таймаутят,
# а 60-секундный таймаут загрузок mix local.hex / mix local.rebar вообще не
# настраивается (HEX_HTTP_TIMEOUT на него не влияет). Поэтому hex и rebar3
# ставим из GitHub, который с тех же хостов работает, а deps.get идёт с
# щадящим таймаутом, без параллелизма и с ретраями.
ENV MIX_ENV=prod LANG=C.UTF-8 HEX_HTTP_TIMEOUT=300 HEX_HTTP_CONCURRENCY=1
WORKDIR /app

RUN i=0; until mix archive.install github hexpm/hex tag v2.5.1 --force; do \
      i=$((i+1)); [ $i -ge 3 ] && exit 1; echo "hex install retry $i"; sleep 5; \
    done
RUN curl -fsSL --retry 5 --retry-delay 5 -o /usr/local/bin/rebar3 \
      https://github.com/erlang/rebar3/releases/download/3.27.0/rebar3 \
    && chmod +x /usr/local/bin/rebar3
ENV MIX_REBAR3=/usr/local/bin/rebar3

COPY server/mix.exs server/mix.lock ./
RUN i=0; until mix deps.get --only prod; do \
      i=$((i+1)); [ $i -ge 5 ] && exit 1; echo "deps.get retry $i"; sleep 15; \
    done

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
