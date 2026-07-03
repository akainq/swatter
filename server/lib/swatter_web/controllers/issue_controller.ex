defmodule SwatterWeb.IssueController do
  use SwatterWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Swatter.{Events, Issues, Projects}
  alias SwatterWeb.{ApiSchemas, Serializer}

  tags(["issues"])

  operation(:index,
    summary: "Issues проекта",
    description: "Сортировки: date (last_seen), new (first_seen), freq (times_seen).",
    parameters: [
      org_slug: [in: :path, type: :string, required: true],
      project_slug: [in: :path, type: :string, required: true],
      status: [
        in: :query,
        schema: %OpenApiSpex.Schema{
          type: :string,
          enum: ["unresolved", "resolved", "ignored", "all"],
          default: "unresolved"
        }
      ],
      sort: [
        in: :query,
        schema: %OpenApiSpex.Schema{
          type: :string,
          enum: ["date", "new", "freq"],
          default: "date"
        }
      ],
      query: [in: :query, type: :string, description: "Поиск по заголовку и culprit"],
      environment: [in: :query, type: :string, description: "Фильтр по окружению событий"],
      release: [in: :query, type: :string, description: "Фильтр по релизу событий"],
      cursor: [in: :query, type: :string, description: "Из Link-заголовка прошлого ответа"],
      limit: [in: :query, schema: %OpenApiSpex.Schema{type: :integer, default: 50, maximum: 100}]
    ],
    responses: [
      ok: {"Issues", "application/json", ApiSchemas.IssueList},
      bad_request: {"Некорректный курсор", "application/json", ApiSchemas.Error},
      not_found: {"Проект не найден", "application/json", ApiSchemas.Error}
    ]
  )

  def index(conn, %{"org_slug" => org_slug, "project_slug" => project_slug} = params) do
    with org when not is_nil(org) <- Projects.get_organization_by_slug(org_slug),
         true <- Swatter.Accounts.member?(conn.assigns.current_user, org.id),
         project when not is_nil(project) <- Projects.get_project_by_slug(org, project_slug) do
      # environment/release — измерения событий в CH: сначала находим id
      # подходящих issues, затем выбираем сами issues из PG
      issue_ids =
        Events.issue_ids_for(project.id,
          environment: params["environment"],
          release: params["release"]
        )

      opts = [
        status: params["status"] || "unresolved",
        sort: params["sort"] || "date",
        query: params["query"],
        issue_ids: issue_ids,
        cursor: params["cursor"],
        limit: parse_limit(params["limit"])
      ]

      case Issues.list_issues(project.id, opts) do
        {:ok, issues, next_cursor} ->
          conn
          |> put_next_link(next_cursor)
          |> json(Enum.map(issues, &Serializer.issue(&1, project)))

        {:error, :invalid_cursor} ->
          conn |> put_status(400) |> json(%{detail: "invalid cursor"})
      end
    else
      _not_found_or_not_member ->
        conn |> put_status(404) |> json(%{detail: "project not found"})
    end
  end

  operation(:filters,
    summary: "Доступные значения фильтров проекта (environment/release)",
    parameters: [
      org_slug: [in: :path, type: :string, required: true],
      project_slug: [in: :path, type: :string, required: true]
    ],
    responses: [
      ok: {"Значения фильтров", "application/json", ApiSchemas.FilterValues},
      not_found: {"Проект не найден", "application/json", ApiSchemas.Error}
    ]
  )

  def filters(conn, %{"org_slug" => org_slug, "project_slug" => project_slug}) do
    with org when not is_nil(org) <- Projects.get_organization_by_slug(org_slug),
         true <- Swatter.Accounts.member?(conn.assigns.current_user, org.id),
         project when not is_nil(project) <- Projects.get_project_by_slug(org, project_slug) do
      json(conn, Events.filter_values(project.id))
    else
      _ -> conn |> put_status(404) |> json(%{detail: "project not found"})
    end
  end

  operation(:show,
    summary: "Деталка issue",
    parameters: [issue_id: [in: :path, type: :integer, required: true]],
    responses: [
      ok: {"Issue", "application/json", ApiSchemas.Issue},
      not_found: {"Не найден", "application/json", ApiSchemas.Error}
    ]
  )

  def show(conn, %{"issue_id" => issue_id}) do
    case fetch_issue(conn, issue_id) do
      nil ->
        conn |> put_status(404) |> json(%{detail: "issue not found"})

      issue ->
        detail =
          issue
          |> Serializer.issue()
          |> Map.merge(%{
            "aiAnalysis" => Serializer.ai_analysis(Swatter.AI.get_analysis(issue.id)),
            "aiEnabled" => Swatter.AI.enabled?()
          })

        json(conn, detail)
    end
  end

  operation(:analyze,
    summary: "Запросить AI-анализ issue (ADR-0016, только по запросу)",
    description:
      "Ставит фоновую джобу анализа на z.ai; результат опрашивается через деталку issue.",
    parameters: [issue_id: [in: :path, type: :integer, required: true]],
    responses: [
      accepted: {"Анализ поставлен в очередь", "application/json", ApiSchemas.AIAnalysis},
      not_found: {"Не найден", "application/json", ApiSchemas.Error},
      unprocessable_entity: {"AI не настроен", "application/json", ApiSchemas.Error}
    ]
  )

  def analyze(conn, %{"issue_id" => issue_id}) do
    with issue when not is_nil(issue) <- fetch_issue(conn, issue_id),
         {:ok, analysis} <- Swatter.AI.request_analysis(issue) do
      conn |> put_status(202) |> json(Serializer.ai_analysis(analysis))
    else
      nil ->
        conn |> put_status(404) |> json(%{detail: "issue not found"})

      {:error, :ai_disabled} ->
        conn
        |> put_status(422)
        |> json(%{detail: "AI analysis is not configured (set ZAI_API_KEY)"})
    end
  end

  operation(:update,
    summary: "Смена статуса (resolve / ignore / unresolve)",
    parameters: [issue_id: [in: :path, type: :integer, required: true]],
    request_body: {"Новый статус", "application/json", ApiSchemas.IssueUpdateRequest},
    responses: [
      ok: {"Обновлённый issue", "application/json", ApiSchemas.Issue},
      bad_request: {"Некорректный статус", "application/json", ApiSchemas.Error},
      not_found: {"Не найден", "application/json", ApiSchemas.Error}
    ]
  )

  def update(conn, %{"issue_id" => issue_id} = params) do
    with issue when not is_nil(issue) <- fetch_issue(conn, issue_id),
         {:ok, updated} <- Issues.update_status(issue, params["status"]) do
      json(conn, Serializer.issue(%{updated | project: issue.project}))
    else
      nil -> conn |> put_status(404) |> json(%{detail: "issue not found"})
      {:error, :invalid_status} -> conn |> put_status(400) |> json(%{detail: "invalid status"})
      {:error, _changeset} -> conn |> put_status(400) |> json(%{detail: "could not update"})
    end
  end

  # nil и для несуществующего, и для чужого issue — не раскрываем их наличие
  defp fetch_issue(conn, issue_id) do
    with {id, ""} <- Integer.parse(to_string(issue_id)),
         %{} = issue <- Issues.get_issue(id),
         true <-
           Swatter.Accounts.member?(conn.assigns.current_user, issue.project.organization_id) do
      issue
    else
      _ -> nil
    end
  end

  defp parse_limit(nil), do: 50

  defp parse_limit(limit) do
    case Integer.parse(to_string(limit)) do
      {n, ""} -> n
      _ -> 50
    end
  end

  defp put_next_link(conn, nil), do: conn

  defp put_next_link(conn, cursor) do
    conn = Plug.Conn.fetch_query_params(conn)
    query = conn.query_params |> Map.put("cursor", cursor) |> URI.encode_query()

    Plug.Conn.put_resp_header(
      conn,
      "link",
      ~s(<#{conn.request_path}?#{query}>; rel="next"; results="true"; cursor="#{cursor}")
    )
  end
end
