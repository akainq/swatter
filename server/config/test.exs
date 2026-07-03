import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :swatter, Swatter.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  # локально — 5433 (compose.yaml); в CI переопределяется через PGPORT=5432
  port: String.to_integer(System.get_env("PGPORT") || "5433"),
  database: "swatter_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# Сервер слушает и в тестах: conformance-тесты шлют события реальными
# Sentry SDK по HTTP (см. test/conformance)
config :swatter, SwatterWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "5XOePkQAR0JgrPrrfYFrzDO4O6WEzARgh7iGntO3EJXU0cJE58uyGxEEdUqcG/rN",
  server: true

# локально — 6380 (compose.yaml); в CI переопределяется через REDIS_PORT=6379
config :swatter, :redis_url, "redis://localhost:#{System.get_env("REDIS_PORT") || "6380"}"

config :swatter, Swatter.EventsRepo,
  url:
    "http://swatter:swatter@localhost:#{System.get_env("CLICKHOUSE_PORT") || "8123"}/swatter_test"

# Пайплайн в тестах не стартует в supervision-дереве приложения:
# интеграционные тесты поднимают его сами (start_supervised) в shared-sandbox
config :swatter, :start_pipeline, false

# Oban в тестах не исполняет джобы — проверяем факт постановки (ADR-0013)
config :swatter, Oban, testing: :manual

# Telegram-HTTP в тестах — через Req.Test (без реального api.telegram.org)
config :swatter, :alerts, req_options: [plug: {Req.Test, Swatter.Alerts.Telegram}]

# z.ai-HTTP в тестах — через Req.Test (без реального api.z.ai)
config :swatter, :ai, req_options: [plug: {Req.Test, Swatter.AI.ZAI}]

# Отдельный стрим и маленькие лимиты, чтобы тесты на 413 не гоняли мегабайты
config :swatter, :ingest,
  stream: "swatter:test:envelopes",
  stream_maxlen: 1000,
  max_compressed_bytes: 1_000_000,
  max_envelope_bytes: 5_000_000

# In test we don't send emails
config :swatter, Swatter.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Быстрое хэширование паролей в тестах
config :pbkdf2_elixir, rounds: 1

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
