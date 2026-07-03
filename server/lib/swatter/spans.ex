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

  @traces_limit 50

  @doc """
  Последние трейсы транзакции (корневые сегменты) за окно.
  `sort`: `"slow"` (по длительности, дефолт) | `"recent"`.
  """
  def recent_traces(project_id, transaction_name, opts \\ []) do
    window = Keyword.get(opts, :window, @default_window)
    seconds = Map.get(@windows, window, @windows[@default_window])
    since = DateTime.add(DateTime.utc_now(), -seconds, :second)

    query =
      from s in Span,
        where:
          s.project_id == ^project_id and s.is_segment == 1 and
            s.transaction_name == ^transaction_name and s.start_ts > ^since,
        limit: @traces_limit,
        select: %{
          trace_id: s.trace_id,
          start_ts: s.start_ts,
          duration_ms: s.duration_ms,
          status: s.status,
          environment: s.environment,
          release: s.release
        }

    query =
      case Keyword.get(opts, :sort, "slow") do
        "recent" -> order_by(query, [s], desc: s.start_ts)
        _slow -> order_by(query, [s], desc: s.duration_ms)
      end

    EventsRepo.all(query)
  end

  @trace_spans_limit 1000

  @doc """
  Все спаны трейса по организации (кросс-проектно — фронт↔бэк↔микросервисы),
  в порядке старта. Bloom-index по trace_id держит выборку точечной.
  """
  def trace_spans(org_id, trace_id) do
    EventsRepo.all(
      from s in Span,
        where: s.org_id == ^org_id and s.trace_id == ^trace_id,
        order_by: [asc: s.start_ts, asc: s.span_id],
        limit: @trace_spans_limit
    )
  end
end
