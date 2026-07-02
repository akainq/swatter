# Conformance: официальный sentry-elixir должен доставить событие в Swatter,
# зная только DSN (ADR-0001). Запуск: SWATTER_DSN=... mix run send_error.exs
{:ok, _} = Application.ensure_all_started(:sentry)

case Sentry.capture_message("conformance: hello from sentry-elixir", result: :sync) do
  {:ok, _event_id} ->
    IO.puts("event sent")

  other ->
    IO.puts(:stderr, "send failed: #{inspect(other)}")
    System.halt(1)
end
