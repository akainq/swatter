defmodule Swatter.Projects do
  @moduledoc """
  Control plane: организации, проекты и DSN-ключи (ADR-0003).
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Swatter.Projects.{Organization, Project, ProjectKey}
  alias Swatter.Repo

  def create_organization(attrs) do
    %Organization{}
    |> Organization.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Создаёт проект вместе с первым DSN-ключом."
  def create_project(%Organization{} = org, attrs) do
    Multi.new()
    |> Multi.insert(:project, fn _ ->
      %Project{organization_id: org.id} |> Project.changeset(attrs)
    end)
    |> Multi.insert(:key, fn %{project: project} ->
      %ProjectKey{project_id: project.id} |> ProjectKey.changeset(%{})
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{project: project, key: key}} -> {:ok, project, key}
      {:error, _step, changeset, _} -> {:error, changeset}
    end
  end

  @doc """
  Ключ для аутентификации ingest: активный, принадлежащий проекту из пути.
  Горячий путь приёма; кэш в ETS — при работах над rate limiting (ADR-0009).
  """
  def get_active_key(project_id, public_key)
      when is_integer(project_id) and is_binary(public_key) do
    Repo.one(
      from k in ProjectKey,
        where: k.project_id == ^project_id and k.public_key == ^public_key and k.active
    )
  end

  def get_project(project_id), do: Repo.get(Project, project_id)

  def list_organizations, do: Repo.all(from o in Organization, order_by: o.slug)

  @doc "Проекты организации с ключами (для DSN в ответе API)."
  def list_projects(%Organization{id: org_id}) do
    Repo.all(
      from p in Project,
        where: p.organization_id == ^org_id,
        order_by: p.slug,
        preload: [:keys]
    )
  end

  @doc """
  Проекты организации со счётчиками: unresolved issues (PG) и события
  за последние 24 часа (CH). По одному группирующему запросу на хранилище.
  """
  def list_projects_with_stats(%Organization{} = org) do
    projects = list_projects(org)
    ids = Enum.map(projects, & &1.id)

    unresolved =
      Repo.all(
        from i in Swatter.Issues.Issue,
          where: i.project_id in ^ids and i.status == "unresolved",
          group_by: i.project_id,
          select: {i.project_id, count(i.id)}
      )
      |> Map.new()

    since = DateTime.utc_now() |> DateTime.add(-86_400, :second)

    events_24h =
      Swatter.EventsRepo.all(
        from e in Swatter.Events.Event,
          where: e.project_id in ^ids and e.timestamp > ^since,
          group_by: e.project_id,
          select: {e.project_id, count(e.event_id)}
      )
      |> Map.new()

    Enum.map(projects, fn project ->
      %{
        project: project,
        unresolved_issues: Map.get(unresolved, project.id, 0),
        events_24h: Map.get(events_24h, project.id, 0)
      }
    end)
  end

  def update_project(%Project{} = project, attrs) do
    project |> Project.update_changeset(attrs) |> Repo.update()
  end

  def get_organization_by_slug(slug), do: Repo.get_by(Organization, slug: slug)

  def get_project_by_slug(%Organization{id: org_id}, slug) do
    Repo.get_by(Project, organization_id: org_id, slug: slug)
  end

  def first_key(%Project{id: project_id}) do
    Repo.one(
      from k in ProjectKey,
        where: k.project_id == ^project_id and k.active,
        order_by: [asc: k.id],
        limit: 1
    )
  end
end
