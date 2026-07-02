import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/swatter start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :swatter, SwatterWeb.Endpoint, server: true
end

# В test порт фиксирован в config/test.exs (4002) — не перекрываем его,
# иначе conformance-тесты и параллельный dev-сервер дерутся за порт
if config_env() != :test do
  config :swatter, SwatterWeb.Endpoint,
    http: [port: String.to_integer(System.get_env("PORT", "4000"))]
end

# Алерты (ADR-0013) и AI-анализ (ADR-0016): секреты и настройки из окружения.
# Нет токена/ключа → соответствующая фича просто выключена (fail-safe).
config :swatter, :alerts,
  telegram_bot_token: System.get_env("TELEGRAM_BOT_TOKEN"),
  telegram_api_base: System.get_env("TELEGRAM_API_BASE") || "https://api.telegram.org",
  cooldown_seconds: String.to_integer(System.get_env("ALERT_COOLDOWN_SECONDS") || "900")

config :swatter, :ai,
  api_key: System.get_env("ZAI_API_KEY"),
  model: System.get_env("ZAI_MODEL") || "glm-4.6",
  base_url: System.get_env("ZAI_BASE_URL") || "https://api.z.ai/api/paas/v4",
  timeout_ms: String.to_integer(System.get_env("ZAI_TIMEOUT_MS") || "60000")

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  redis_url =
    System.get_env("REDIS_URL") ||
      raise """
      environment variable REDIS_URL is missing.
      For example: redis://localhost:6379
      """

  config :swatter, :redis_url, redis_url

  clickhouse_url =
    System.get_env("CLICKHOUSE_URL") ||
      raise """
      environment variable CLICKHOUSE_URL is missing.
      For example: http://user:pass@localhost:8123/swatter
      """

  config :swatter, Swatter.EventsRepo, url: clickhouse_url

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :swatter, Swatter.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :swatter, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :swatter, SwatterWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :swatter, SwatterWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :swatter, SwatterWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :swatter, Swatter.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://swoosh.hexdocs.pm/Swoosh.html#module-installation for details.
end
