import Config

config :sentry,
  dsn: System.get_env("SWATTER_DSN"),
  environment_name: "conformance",
  release: "conformance@0.0.1"
