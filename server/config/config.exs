# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :swatter,
  ecto_repos: [Swatter.Repo, Swatter.EventsRepo],
  generators: [timestamp_type: :utc_datetime]

config :swatter, Swatter.EventsRepo, priv: "priv/events_repo"

# Configure the endpoint
config :swatter, SwatterWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: SwatterWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Swatter.PubSub,
  live_view: [signing_salt: "zjPRF38H"]

# Приём событий (ADR-0001/0005): стрим-буфер и лимиты размеров.
# Лимиты — потолки, а не тюнинг: compressed ограничивает чтение тела,
# envelope — результат распаковки (защита от decompression-бомб).
config :swatter, :ingest,
  stream: "swatter:envelopes",
  stream_maxlen: 100_000,
  max_compressed_bytes: 20_000_000,
  max_envelope_bytes: 50_000_000,
  # дефолтный лимит на DSN-ключ (ADR-0009); переопределяется per-key
  rate_limit: [count: 3000, window_seconds: 60]

# Пайплайн обработки (ADR-0005): consumer group поверх стрима
config :swatter, :pipeline,
  group: "swatter-pipeline",
  processor_concurrency: 4,
  batch_size: 500,
  batch_timeout: 1_000

# Фоновые задачи (ADR-0002/0013): Oban поверх PostgreSQL.
# alerts — доставка в Telegram, ai — анализ issues (ADR-0016).
config :swatter, Oban,
  repo: Swatter.Repo,
  queues: [alerts: 10, ai: 3],
  plugins: [{Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7}]

# sourcemap-артефакты (ADR-0012): потолок размера распакованного файла
config :swatter, :artifacts, max_bytes: 30_000_000

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :swatter, Swatter.Mailer, adapter: Swoosh.Adapters.Local

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
