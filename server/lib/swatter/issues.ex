defmodule Swatter.Issues do
  @moduledoc """
  Issues — сгруппированные события (ADR-0006). Создаются и обновляются
  только пайплайном через `upsert_from_event/3`; статусами управляет
  dashboard API.
  """

  import Ecto.Query

  alias Swatter.Issues.Issue
  alias Swatter.Releases.Release
  alias Swatter.Repo

  @doc """
  Новое событие либо создаёт issue, либо обновляет счётчики. `release` —
  `%Release{}` события или nil.

  Статус в UPSERT не трогается (чтобы вернулся прежний статус для
  regression-логики); переоткрытие resolved-issue и пометка регрессии —
  отдельным шагом `maybe_reopen/2` по сравнению порядков релизов (ADR-0011).
  """
  def upsert_from_event(normalized, org_id, project_id, release \\ nil) do
    now = DateTime.utc_now()
    release_id = release && release.id

    on_conflict =
      from(i in Issue,
        update: [
          inc: [times_seen: 1],
          set: [
            last_seen: fragment("GREATEST(?, EXCLUDED.last_seen)", i.last_seen),
            level: fragment("EXCLUDED.level"),
            first_release_id:
              fragment("COALESCE(?, EXCLUDED.first_release_id)", i.first_release_id),
            updated_at: ^now
          ]
        ]
      )

    %Issue{
      organization_id: org_id,
      project_id: project_id,
      fingerprint_hash: normalized.fingerprint_hash,
      grouping_version: normalized.grouping_version,
      title: normalized.title,
      culprit: normalized.culprit,
      level: normalized.level,
      status: "unresolved",
      first_seen: normalized.timestamp,
      last_seen: normalized.timestamp,
      first_release_id: release_id,
      times_seen: 1
    }
    |> Repo.insert(
      on_conflict: on_conflict,
      conflict_target: [:project_id, :fingerprint_hash],
      returning: true
    )
    |> case do
      {:ok, issue} ->
        kind = classify(issue)

        case maybe_reopen(issue, release) do
          {:ok, final} -> {:ok, %{final | event_kind: kind}}
          error -> error
        end

      error ->
        error
    end
  end

  # вид события для алертов (ADR-0013), по состоянию issue ДО reopen:
  # первое появление — "new", возврат из resolved — "regression", иначе "ongoing"
  defp classify(%Issue{times_seen: 1}), do: "new"
  defp classify(%Issue{status: "resolved"}), do: "regression"
  defp classify(_issue), do: "ongoing"

  # resolved-issue при новом событии переоткрывается; регрессия — только
  # если событие в релизе строго новее того, где issue закрыли
  defp maybe_reopen(%Issue{status: "resolved"} = issue, release) do
    issue
    |> Ecto.Changeset.change(status: "unresolved", regressed: regression?(issue, release))
    |> Repo.update()
  end

  defp maybe_reopen(issue, _release), do: {:ok, issue}

  defp regression?(%Issue{resolved_in_release_id: nil}, _release), do: false
  defp regression?(_issue, nil), do: false

  defp regression?(%Issue{resolved_in_release_id: resolved_id}, %Release{ordinal: ordinal}) do
    case Repo.get(Release, resolved_id) do
      %Release{ordinal: resolved_ordinal} -> ordinal > resolved_ordinal
      _ -> false
    end
  end

  def get_issue(project_id, issue_id) do
    Repo.get_by(Issue, id: issue_id, project_id: project_id)
  end

  def get_issue(issue_id) do
    Issue |> Repo.get(issue_id) |> Repo.preload(project: :organization)
  end

  @list_max_limit 100
  @list_default_limit 50

  @doc """
  Список issues проекта с keyset-пагинацией (ADR-0008: cursor, не offset).

  opts: `:status` ("unresolved" по умолчанию; "all" — без фильтра),
  `:sort` ("date" = last_seen | "new" = first_seen | "freq" = times_seen),
  `:cursor` (из прошлого ответа), `:limit` (≤ #{@list_max_limit}).

  Возвращает `{:ok, issues, next_cursor | nil}` либо `{:error, :invalid_cursor}`.
  """
  def list_issues(project_id, opts \\ []) do
    status = Keyword.get(opts, :status, "unresolved")
    sort = Keyword.get(opts, :sort, "date")
    limit = opts |> Keyword.get(:limit, @list_default_limit) |> min(@list_max_limit) |> max(1)

    query =
      Issue
      |> where(project_id: ^project_id)
      |> filter_status(status)
      |> filter_query(Keyword.get(opts, :query))
      |> filter_issue_ids(Keyword.get(opts, :issue_ids, :all))
      |> sort_issues(sort)
      |> limit(^(limit + 1))

    with {:ok, query} <- apply_cursor(query, sort, Keyword.get(opts, :cursor)) do
      case Repo.all(query) do
        issues when length(issues) > limit ->
          issues = Enum.take(issues, limit)
          {:ok, issues, encode_cursor(List.last(issues), sort)}

        issues ->
          {:ok, issues, nil}
      end
    end
  end

  # текстовый поиск по заголовку и culprit
  defp filter_query(query, q) when is_binary(q) do
    case String.trim(q) do
      "" ->
        query

      trimmed ->
        pattern = "%" <> escape_like(trimmed) <> "%"
        where(query, [i], ilike(i.title, ^pattern) or ilike(i.culprit, ^pattern))
    end
  end

  defp filter_query(query, _), do: query

  # ограничение множеством id, полученным из CH по environment/release;
  # :all — фильтров нет, пустой список — совпадений нет
  defp filter_issue_ids(query, :all), do: query
  defp filter_issue_ids(query, []), do: where(query, [i], false)
  defp filter_issue_ids(query, ids) when is_list(ids), do: where(query, [i], i.id in ^ids)

  defp escape_like(string) do
    String.replace(string, ~r/[\\%_]/, fn ch -> "\\" <> ch end)
  end

  defp filter_status(query, "all"), do: query

  defp filter_status(query, status) when status in ~w(unresolved resolved ignored),
    do: where(query, status: ^status)

  defp filter_status(query, _), do: where(query, status: "unresolved")

  defp sort_issues(query, "new"), do: order_by(query, [i], desc: i.first_seen, desc: i.id)
  defp sort_issues(query, "freq"), do: order_by(query, [i], desc: i.times_seen, desc: i.id)
  defp sort_issues(query, _date), do: order_by(query, [i], desc: i.last_seen, desc: i.id)

  defp apply_cursor(query, _sort, nil), do: {:ok, query}

  defp apply_cursor(query, sort, cursor) do
    with {:ok, decoded} <- Base.url_decode64(cursor, padding: false),
         [value, id] <- String.split(decoded, "|", parts: 2),
         {id, ""} <- Integer.parse(id),
         {:ok, query} <- cursor_where(query, sort, value, id) do
      {:ok, query}
    else
      _ -> {:error, :invalid_cursor}
    end
  end

  defp cursor_where(query, "freq", value, id) do
    case Integer.parse(value) do
      {count, ""} ->
        {:ok, where(query, [i], fragment("(?, ?) < (?, ?)", i.times_seen, i.id, ^count, ^id))}

      _ ->
        {:error, :invalid_cursor}
    end
  end

  defp cursor_where(query, sort, value, id) do
    with {us, ""} <- Integer.parse(value),
         {:ok, dt} <- DateTime.from_unix(us, :microsecond) do
      field = if sort == "new", do: :first_seen, else: :last_seen

      {:ok, where(query, [i], fragment("(?, ?) < (?, ?)", field(i, ^field), i.id, ^dt, ^id))}
    else
      _ -> {:error, :invalid_cursor}
    end
  end

  defp encode_cursor(issue, sort) do
    value =
      case sort do
        "freq" -> Integer.to_string(issue.times_seen)
        "new" -> issue.first_seen |> DateTime.to_unix(:microsecond) |> Integer.to_string()
        _date -> issue.last_seen |> DateTime.to_unix(:microsecond) |> Integer.to_string()
      end

    Base.url_encode64("#{value}|#{issue.id}", padding: false)
  end

  @doc """
  Смена статуса из dashboard API. При resolve запоминаем последний релиз
  проекта (`resolved_in_release_id`) — база для regression-детекта — и
  снимаем флаг `regressed`.
  """
  def update_status(%Issue{} = issue, "resolved") do
    resolved_in =
      Repo.one(
        from r in Release,
          where: r.project_id == ^issue.project_id,
          order_by: [desc: r.ordinal],
          limit: 1,
          select: r.id
      )

    issue
    |> Ecto.Changeset.change(
      status: "resolved",
      resolved_in_release_id: resolved_in,
      regressed: false
    )
    |> Repo.update()
  end

  def update_status(%Issue{} = issue, status) when status in ~w(unresolved ignored) do
    issue |> Ecto.Changeset.change(status: status, regressed: false) |> Repo.update()
  end

  def update_status(%Issue{}, _), do: {:error, :invalid_status}
end
