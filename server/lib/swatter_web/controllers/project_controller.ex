defmodule SwatterWeb.ProjectController do
  use SwatterWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Swatter.Projects
  alias SwatterWeb.{ApiSchemas, Serializer}

  tags(["projects"])

  operation(:index,
    summary: "Проекты организации (с DSN и счётчиками)",
    parameters: [
      org_slug: [in: :path, type: :string, required: true]
    ],
    responses: [
      ok:
        {"Проекты", "application/json",
         %OpenApiSpex.Schema{type: :array, items: ApiSchemas.Project}},
      not_found: {"Организация не найдена", "application/json", ApiSchemas.Error}
    ]
  )

  def index(conn, %{"org_slug" => org_slug}) do
    case authorized_org(conn, org_slug) do
      nil ->
        conn |> put_status(404) |> json(%{detail: "organization not found"})

      org ->
        base_url = SwatterWeb.Endpoint.url()

        json(
          conn,
          Enum.map(
            Projects.list_projects_with_stats(org),
            &Serializer.project_with_stats(&1, base_url)
          )
        )
    end
  end

  operation(:update,
    summary: "Переименовать проект (slug неизменяем)",
    parameters: [
      org_slug: [in: :path, type: :string, required: true],
      project_slug: [in: :path, type: :string, required: true]
    ],
    request_body: {"Изменения", "application/json", ApiSchemas.ProjectUpdateRequest},
    responses: [
      ok: {"Обновлённый проект", "application/json", ApiSchemas.Project},
      bad_request: {"Ошибка валидации", "application/json", ApiSchemas.Error},
      not_found: {"Проект не найден", "application/json", ApiSchemas.Error}
    ]
  )

  def update(conn, %{"org_slug" => org_slug, "project_slug" => project_slug} = params) do
    with org when not is_nil(org) <- authorized_org(conn, org_slug),
         project when not is_nil(project) <- Projects.get_project_by_slug(org, project_slug) do
      case Projects.update_project(project, Map.take(params, ["name", "platform"])) do
        {:ok, updated} ->
          updated = Swatter.Repo.preload(updated, :keys)
          json(conn, Serializer.project(updated, SwatterWeb.Endpoint.url()))

        {:error, changeset} ->
          conn |> put_status(400) |> json(%{detail: Serializer.changeset_detail(changeset)})
      end
    else
      nil -> conn |> put_status(404) |> json(%{detail: "project not found"})
    end
  end

  operation(:delete,
    summary: "Удалить проект со всеми данными (issues, события, релизы, DSN)",
    parameters: [
      org_slug: [in: :path, type: :string, required: true],
      project_slug: [in: :path, type: :string, required: true]
    ],
    responses: [
      no_content: "Удалён",
      not_found: {"Проект не найден", "application/json", ApiSchemas.Error}
    ]
  )

  def delete(conn, %{"org_slug" => org_slug, "project_slug" => project_slug}) do
    with org when not is_nil(org) <- authorized_org(conn, org_slug),
         project when not is_nil(project) <- Projects.get_project_by_slug(org, project_slug) do
      :ok = Projects.delete_project(project)
      send_resp(conn, 204, "")
    else
      nil -> conn |> put_status(404) |> json(%{detail: "project not found"})
    end
  end

  operation(:create,
    summary: "Создать проект (сразу с DSN-ключом)",
    parameters: [
      org_slug: [in: :path, type: :string, required: true]
    ],
    request_body: {"Проект", "application/json", ApiSchemas.ProjectCreateRequest},
    responses: [
      created: {"Созданный проект", "application/json", ApiSchemas.Project},
      bad_request: {"Ошибка валидации", "application/json", ApiSchemas.Error},
      not_found: {"Организация не найдена", "application/json", ApiSchemas.Error}
    ]
  )

  def create(conn, %{"org_slug" => org_slug} = params) do
    case authorized_org(conn, org_slug) do
      nil ->
        conn |> put_status(404) |> json(%{detail: "organization not found"})

      org ->
        attrs = Map.take(params, ["name", "slug", "platform"])

        case Projects.create_project(org, attrs) do
          {:ok, project, key} ->
            conn
            |> put_status(201)
            |> json(Serializer.project(%{project | keys: [key]}, SwatterWeb.Endpoint.url()))

          {:error, changeset} ->
            conn |> put_status(400) |> json(%{detail: Serializer.changeset_detail(changeset)})
        end
    end
  end

  # членство обязательно; чужие организации неотличимы от несуществующих
  defp authorized_org(conn, org_slug) do
    org = Projects.get_organization_by_slug(org_slug)

    if org && Swatter.Accounts.member?(conn.assigns.current_user, org.id) do
      org
    end
  end
end
