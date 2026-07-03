defmodule SwatterWeb.PerformanceController do
  use SwatterWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Swatter.{Projects, Spans}
  alias SwatterWeb.{ApiSchemas, Serializer}

  tags(["performance"])

  operation(:transactions,
    summary: "Агрегаты по транзакциям проекта (ADR-0014, на лету из CH)",
    parameters: [
      org_slug: [in: :path, type: :string, required: true],
      project_slug: [in: :path, type: :string, required: true],
      window: [
        in: :query,
        schema: %OpenApiSpex.Schema{type: :string, enum: ["1h", "24h", "7d"], default: "24h"}
      ]
    ],
    responses: [
      ok: {"Транзакции", "application/json", ApiSchemas.TransactionStatList},
      not_found: {"Проект не найден", "application/json", ApiSchemas.Error}
    ]
  )

  def transactions(conn, %{"org_slug" => org_slug, "project_slug" => project_slug} = params) do
    with org when not is_nil(org) <- Projects.get_organization_by_slug(org_slug),
         true <- Swatter.Accounts.member?(conn.assigns.current_user, org.id),
         project when not is_nil(project) <- Projects.get_project_by_slug(org, project_slug) do
      stats = Spans.transaction_stats(project.id, params["window"] || "24h")
      json(conn, Enum.map(stats, &Serializer.transaction_stat/1))
    else
      _ -> conn |> put_status(404) |> json(%{detail: "project not found"})
    end
  end

  operation(:traces,
    summary: "Последние трейсы транзакции (корневые сегменты)",
    parameters: [
      org_slug: [in: :path, type: :string, required: true],
      project_slug: [in: :path, type: :string, required: true],
      transaction: [in: :query, type: :string, required: true],
      window: [
        in: :query,
        schema: %OpenApiSpex.Schema{type: :string, enum: ["1h", "24h", "7d"], default: "24h"}
      ],
      sort: [
        in: :query,
        schema: %OpenApiSpex.Schema{type: :string, enum: ["slow", "recent"], default: "slow"}
      ]
    ],
    responses: [
      ok: {"Трейсы", "application/json", ApiSchemas.TraceSummaryList},
      not_found: {"Проект не найден", "application/json", ApiSchemas.Error}
    ]
  )

  def traces(conn, %{"org_slug" => org_slug, "project_slug" => project_slug} = params) do
    with org when not is_nil(org) <- Projects.get_organization_by_slug(org_slug),
         true <- Swatter.Accounts.member?(conn.assigns.current_user, org.id),
         project when not is_nil(project) <- Projects.get_project_by_slug(org, project_slug) do
      traces =
        Spans.recent_traces(project.id, params["transaction"] || "",
          window: params["window"] || "24h",
          sort: params["sort"] || "slow"
        )

      json(conn, Enum.map(traces, &Serializer.trace_summary/1))
    else
      _ -> conn |> put_status(404) |> json(%{detail: "project not found"})
    end
  end

  operation(:trace,
    summary: "Спаны трейса по организации (кросс-проектно, ADR-0014)",
    parameters: [
      org_slug: [in: :path, type: :string, required: true],
      trace_id: [in: :path, type: :string, required: true]
    ],
    responses: [
      ok: {"Трейс", "application/json", ApiSchemas.Trace},
      not_found: {"Трейс не найден", "application/json", ApiSchemas.Error}
    ]
  )

  def trace(conn, %{"org_slug" => org_slug, "trace_id" => trace_id}) do
    with org when not is_nil(org) <- Projects.get_organization_by_slug(org_slug),
         true <- Swatter.Accounts.member?(conn.assigns.current_user, org.id),
         [_ | _] = spans <- Spans.trace_spans(org.id, normalize_trace_id(trace_id)) do
      # слаги проектов — для кросс-сервисных бейджей в waterfall (PG, не JOIN в CH)
      slugs = org |> Projects.list_projects() |> Map.new(&{&1.id, &1.slug})

      json(conn, %{
        "traceId" => normalize_trace_id(trace_id),
        "spans" => Enum.map(spans, &Serializer.trace_span(&1, slugs))
      })
    else
      _ -> conn |> put_status(404) |> json(%{detail: "trace not found"})
    end
  end

  defp normalize_trace_id(trace_id) do
    trace_id |> String.replace("-", "") |> String.downcase()
  end
end
