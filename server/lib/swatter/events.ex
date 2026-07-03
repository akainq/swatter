defmodule Swatter.Events do
  @moduledoc """
  Чтение событий из ClickHouse для dashboard API (ADR-0003: только
  аналитические чтения, никаких построчных мутаций).
  """

  import Ecto.Query

  alias Swatter.Events.Event
  alias Swatter.EventsRepo

  @default_limit 50
  @max_limit 100

  @filter_values_limit 200

  @doc """
  Доступные значения фильтров проекта (environment/release) из событий CH.
  Ограничены #{@filter_values_limit} самыми свежими значениями каждого.
  """
  def filter_values(project_id) do
    %{
      environments: distinct_values(project_id, :environment),
      releases: distinct_values(project_id, :release)
    }
  end

  defp distinct_values(project_id, field) do
    EventsRepo.all(
      from e in Event,
        where: e.project_id == ^project_id and field(e, ^field) != "",
        group_by: field(e, ^field),
        order_by: [desc: max(e.timestamp)],
        select: field(e, ^field),
        limit: @filter_values_limit
    )
  end

  @doc """
  id issues проекта, у которых есть события с заданными environment/release
  (измерения живут в CH, не в PG). Возвращает `:all`, если фильтров нет.
  """
  def issue_ids_for(project_id, filters) do
    env = presence(filters[:environment])
    release = presence(filters[:release])

    if is_nil(env) and is_nil(release) do
      :all
    else
      query =
        from e in Event,
          where: e.project_id == ^project_id,
          group_by: e.issue_id,
          select: e.issue_id

      query = if env, do: where(query, [e], e.environment == ^env), else: query
      query = if release, do: where(query, [e], e.release == ^release), else: query

      EventsRepo.all(query)
    end
  end

  defp presence(nil), do: nil
  defp presence(""), do: nil
  defp presence(value) when is_binary(value), do: value

  @related_limit 100

  @doc """
  Ошибки с этим `trace_id` по всем проектам организации (ADR-0014):
  кросс-сервисная связка фронт↔бэк↔микросервисы. Новые сверху.
  """
  def related_by_trace(org_id, trace_id) do
    EventsRepo.all(
      from e in Event,
        where: e.org_id == ^org_id and e.trace_id == ^trace_id and e.trace_id != "",
        order_by: [desc: e.timestamp],
        limit: @related_limit,
        select: %{
          event_id: e.event_id,
          issue_id: e.issue_id,
          project_id: e.project_id,
          timestamp: e.timestamp,
          level: e.level,
          exception_type: e.exception_type,
          exception_value: e.exception_value,
          message: e.message
        }
    )
  end

  def latest_event(issue_id) do
    Event
    |> where(issue_id: ^issue_id)
    |> order_by([e], desc: e.timestamp, desc: e.event_id)
    |> limit(1)
    |> EventsRepo.one()
  end

  @doc """
  События issue, новые сверху, keyset-курсор `(timestamp, event_id)`.
  Возвращает `{:ok, events, next_cursor | nil}` или `{:error, :invalid_cursor}`.
  """
  def list_events(issue_id, opts \\ []) do
    limit = opts |> Keyword.get(:limit, @default_limit) |> min(@max_limit) |> max(1)

    query =
      Event
      |> where(issue_id: ^issue_id)
      |> order_by([e], desc: e.timestamp, desc: e.event_id)
      |> limit(^(limit + 1))

    with {:ok, query} <- apply_cursor(query, Keyword.get(opts, :cursor)) do
      case EventsRepo.all(query) do
        events when length(events) > limit ->
          events = Enum.take(events, limit)
          {:ok, events, encode_cursor(List.last(events))}

        events ->
          {:ok, events, nil}
      end
    end
  end

  defp apply_cursor(query, nil), do: {:ok, query}

  defp apply_cursor(query, cursor) do
    with {:ok, decoded} <- Base.url_decode64(cursor, padding: false),
         [ms, event_id] <- String.split(decoded, "|", parts: 2),
         {ms, ""} <- Integer.parse(ms),
         {:ok, dt} <- DateTime.from_unix(ms, :millisecond) do
      {:ok,
       where(query, [e], fragment("(?, ?) < (?, ?)", e.timestamp, e.event_id, ^dt, ^event_id))}
    else
      _ -> {:error, :invalid_cursor}
    end
  end

  defp encode_cursor(event) do
    ms = DateTime.to_unix(event.timestamp, :millisecond)
    Base.url_encode64("#{ms}|#{event.event_id}", padding: false)
  end
end
