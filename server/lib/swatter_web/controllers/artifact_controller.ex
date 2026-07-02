defmodule SwatterWeb.ArtifactController do
  use SwatterWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Swatter.{Artifacts, Projects}
  alias SwatterWeb.ApiSchemas

  tags(["artifacts"])

  operation(:create,
    summary: "Загрузка sourcemap-артефакта (multipart, ADR-0012)",
    description: """
    Поля формы: `file` (файл), `debug_id`, `type` (source_map |
    minified_source), опц. `name`. Идемпотентно по (project, debug_id,
    type) — повтор заменяет.
    """,
    parameters: [
      org_slug: [in: :path, type: :string, required: true],
      project_slug: [in: :path, type: :string, required: true]
    ],
    request_body:
      {"multipart-форма", "multipart/form-data",
       %OpenApiSpex.Schema{
         type: :object,
         properties: %{
           file: %OpenApiSpex.Schema{type: :string, format: :binary},
           debug_id: %OpenApiSpex.Schema{type: :string},
           type: %OpenApiSpex.Schema{type: :string, enum: ["source_map", "minified_source"]},
           name: %OpenApiSpex.Schema{type: :string}
         },
         required: [:file, :debug_id, :type]
       }},
    responses: [
      created: {"Загружено", "application/json", ApiSchemas.Artifact},
      bad_request: {"Некорректная форма", "application/json", ApiSchemas.Error},
      request_entity_too_large: {"Файл слишком большой", "application/json", ApiSchemas.Error},
      not_found: {"Проект не найден", "application/json", ApiSchemas.Error}
    ]
  )

  def create(conn, %{"org_slug" => org_slug, "project_slug" => project_slug} = params) do
    # авторизация проекта отдельно от валидации формы: иначе nil «нет
    # проекта» и nil «нет файла» в else неразличимы
    case authorized_project(conn, org_slug, project_slug) do
      nil -> conn |> put_status(404) |> json(%{detail: "project not found"})
      project -> store_artifact(conn, project, params)
    end
  end

  defp store_artifact(conn, project, params) do
    max_bytes = Application.fetch_env!(:swatter, :artifacts)[:max_bytes]

    with %Plug.Upload{path: path} <- params["file"],
         debug_id when is_binary(debug_id) and debug_id != "" <- params["debug_id"],
         type when type in ~w(source_map minified_source) <- params["type"],
         {:ok, %{size: size}} <- File.stat(path),
         :ok <- if(size <= max_bytes, do: :ok, else: :too_large),
         {:ok, content} <- File.read(path),
         {:ok, bundle} <- Artifacts.put(project.id, debug_id, type, content, params["name"]) do
      conn
      |> put_status(201)
      |> json(%{
        id: to_string(bundle.id),
        debugId: bundle.debug_id,
        type: bundle.type,
        name: bundle.name,
        size: bundle.content_size
      })
    else
      :too_large ->
        conn |> put_status(413) |> json(%{detail: "artifact too large"})

      _ ->
        conn |> put_status(400) |> json(%{detail: "file, debug_id and valid type are required"})
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
