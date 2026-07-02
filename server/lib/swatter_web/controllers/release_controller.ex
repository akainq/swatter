defmodule SwatterWeb.ReleaseController do
  use SwatterWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Swatter.{Projects, Releases}
  alias SwatterWeb.{ApiSchemas, Serializer}

  tags(["releases"])

  operation(:index,
    summary: "Релизы проекта (новые сверху) со счётчиком новых issues",
    parameters: [
      org_slug: [in: :path, type: :string, required: true],
      project_slug: [in: :path, type: :string, required: true]
    ],
    responses: [
      ok:
        {"Релизы", "application/json",
         %OpenApiSpex.Schema{type: :array, items: ApiSchemas.Release}},
      not_found: {"Проект не найден", "application/json", ApiSchemas.Error}
    ]
  )

  def index(conn, %{"org_slug" => org_slug, "project_slug" => project_slug}) do
    with %{} = project <- authorized_project(conn, org_slug, project_slug) do
      json(conn, Enum.map(Releases.list_releases_with_counts(project.id), &Serializer.release/1))
    else
      _ -> conn |> put_status(404) |> json(%{detail: "project not found"})
    end
  end

  operation(:show,
    summary: "Релиз и issues, впервые появившиеся в нём",
    parameters: [
      org_slug: [in: :path, type: :string, required: true],
      project_slug: [in: :path, type: :string, required: true],
      version: [in: :path, type: :string, required: true]
    ],
    responses: [
      ok: {"Релиз с новыми issues", "application/json", ApiSchemas.ReleaseDetail},
      not_found: {"Не найдено", "application/json", ApiSchemas.Error}
    ]
  )

  def show(conn, %{"org_slug" => org_slug, "project_slug" => project_slug, "version" => version}) do
    with %{} = project <- authorized_project(conn, org_slug, project_slug),
         %{} = release <- Releases.get_release(project.id, version) do
      body =
        Serializer.release(release)
        |> Map.put(
          "newIssues",
          Enum.map(Releases.new_issues(release), &Serializer.issue(&1, project))
        )

      json(conn, body)
    else
      _ -> conn |> put_status(404) |> json(%{detail: "not found"})
    end
  end

  defp authorized_project(conn, org_slug, project_slug) do
    with org when not is_nil(org) <- Projects.get_organization_by_slug(org_slug),
         true <- Swatter.Accounts.member?(conn.assigns.current_user, org.id),
         project when not is_nil(project) <- Projects.get_project_by_slug(org, project_slug) do
      project
    else
      _ -> nil
    end
  end
end
