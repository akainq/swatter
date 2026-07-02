# conformance-тесты гоняют реальные Sentry SDK (нужны bun и сеть):
# запускаются отдельно через `mix test --only conformance`
ExUnit.start(exclude: [:conformance])
Ecto.Adapters.SQL.Sandbox.mode(Swatter.Repo, :manual)
