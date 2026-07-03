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
end
