defmodule Swatter.Spans do
  @moduledoc """
  Чтение спанов из ClickHouse (ADR-0014): агрегаты по транзакциям на лету
  (quantile-функции CH по корневым строкам, без предагрегатов) и выборки
  трейсов для waterfall. Только аналитические чтения (ADR-0003).
  """

  import Ecto.Query

  alias Swatter.EventsRepo
  alias Swatter.Spans.Span

  @windows %{"1h" => 3600, "24h" => 86_400, "7d" => 604_800}
  @default_window "24h"
  @list_limit 100

  @doc "Допустимые значения окна агрегации."
  def windows, do: Map.keys(@windows)

  @doc """
  Агрегаты по транзакциям проекта за окно (`"1h" | "24h" | "7d"`):
  count / p50 / p95 / rpm / lastSeen, самые частые сверху.
  """
  def transaction_stats(project_id, window \\ @default_window) do
    seconds = Map.get(@windows, window, @windows[@default_window])
    since = DateTime.add(DateTime.utc_now(), -seconds, :second)

    rows =
      EventsRepo.all(
        from s in Span,
          where: s.project_id == ^project_id and s.is_segment == 1 and s.start_ts > ^since,
          group_by: s.transaction_name,
          select: %{
            transaction: s.transaction_name,
            count: count(s.span_id),
            p50: fragment("quantile(0.5)(?)", s.duration_ms),
            p95: fragment("quantile(0.95)(?)", s.duration_ms),
            last_seen: max(s.start_ts)
          },
          order_by: [desc: count(s.span_id)],
          limit: @list_limit
      )

    minutes = seconds / 60
    Enum.map(rows, &Map.put(&1, :rpm, &1.count / minutes))
  end
end
