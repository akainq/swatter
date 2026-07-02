defmodule Swatter.Releases do
  @moduledoc """
  Релизы проекта (ADR-0011). Порядок — монотонный `ordinal` в рамках
  проекта (по времени первого появления), он же основа regression-детекта:
  «новее» = больший ordinal, без разбора семантики версий.
  """

  import Ecto.Query

  alias Swatter.Releases.Release
  alias Swatter.Repo

  @doc """
  Возвращает release проекта по version, создавая при первом появлении.
  ordinal назначается атомарно как max+1 в рамках проекта.
  Горячий путь пайплайна; ошибки гонки на unique-индексе — ретраем чтением.
  """
  def get_or_create(project_id, version, seen_at \\ nil)

  def get_or_create(_project_id, version, _seen_at) when version in [nil, ""], do: nil

  def get_or_create(project_id, version, seen_at) do
    case Repo.get_by(Release, project_id: project_id, version: version) do
      %Release{} = release ->
        release

      nil ->
        insert_release(project_id, version, seen_at)
    end
  end

  defp insert_release(project_id, version, seen_at) do
    next_ordinal =
      Repo.one(
        from r in Release, where: r.project_id == ^project_id, select: coalesce(max(r.ordinal), 0)
      ) + 1

    attrs = %Release{
      project_id: project_id,
      version: version,
      ordinal: next_ordinal,
      # :utc_datetime_usec требует precision 6 (SDK/пайплайн дают меньше)
      first_event_at: seen_at && to_usec(seen_at)
    }

    case Repo.insert(attrs, on_conflict: :nothing) do
      {:ok, %Release{id: id} = release} when not is_nil(id) ->
        release

      # гонка: параллельная вставка того же version — читаем существующий
      _ ->
        Repo.get_by!(Release, project_id: project_id, version: version)
    end
  end

  @doc "Релизы проекта (новые сверху) со счётчиком новых в них issues."
  def list_releases_with_counts(project_id, limit \\ 100) do
    releases =
      Repo.all(
        from r in Release,
          where: r.project_id == ^project_id,
          order_by: [desc: r.ordinal],
          limit: ^limit
      )

    counts = new_issue_counts(Enum.map(releases, & &1.id))
    Enum.map(releases, fn r -> %{release: r, new_issues: Map.get(counts, r.id, 0)} end)
  end

  defp new_issue_counts([]), do: %{}

  defp new_issue_counts(release_ids) do
    Repo.all(
      from i in Swatter.Issues.Issue,
        where: i.first_release_id in ^release_ids,
        group_by: i.first_release_id,
        select: {i.first_release_id, count(i.id)}
    )
    |> Map.new()
  end

  defp to_usec(%DateTime{microsecond: {us, _}} = dt), do: %{dt | microsecond: {us, 6}}

  def get_release(project_id, version) do
    Repo.get_by(Release, project_id: project_id, version: version)
  end

  @doc "Issues, впервые появившиеся в этом релизе (first_release_id)."
  def new_issues(%Release{id: release_id}, limit \\ 100) do
    Repo.all(
      from i in Swatter.Issues.Issue,
        where: i.first_release_id == ^release_id,
        order_by: [desc: i.last_seen],
        limit: ^limit
    )
  end
end
