defmodule SwatterWeb.AlertSettingsController do
  use SwatterWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Swatter.{Alerts, Projects}
  alias SwatterWeb.{ApiSchemas, Serializer}

  tags(["alerts"])

  operation(:show,
    summary: "Настройки Telegram-алертов проекта (ADR-0013)",
    parameters: [
      org_slug: [in: :path, type: :string, required: true],
      project_slug: [in: :path, type: :string, required: true]
    ],
    responses: [
      ok: {"Настройки", "application/json", ApiSchemas.AlertSettings},
      not_found: {"Проект не найден", "application/json", ApiSchemas.Error}
    ]
  )

  def show(conn, %{"org_slug" => org_slug, "project_slug" => project_slug}) do
    with_project(conn, org_slug, project_slug, fn conn, project ->
      settings = Alerts.get_settings(project.id)
      json(conn, Serializer.alert_settings(settings, telegram_configured?()))
    end)
  end

  operation(:update,
    summary: "Обновить настройки алертов проекта",
    description: "Частичное обновление: применяются только присланные поля.",
    parameters: [
      org_slug: [in: :path, type: :string, required: true],
      project_slug: [in: :path, type: :string, required: true]
    ],
    request_body: {"Изменения", "application/json", ApiSchemas.AlertSettingsUpdateRequest},
    responses: [
      ok: {"Обновлённые настройки", "application/json", ApiSchemas.AlertSettings},
      bad_request: {"Ошибка валидации", "application/json", ApiSchemas.Error},
      not_found: {"Проект не найден", "application/json", ApiSchemas.Error}
    ]
  )

  @field_mapping %{
    "enabled" => :enabled,
    "telegramChatId" => :telegram_chat_id,
    "onNewIssue" => :on_new_issue,
    "onRegression" => :on_regression,
    "frequencyThreshold" => :frequency_threshold,
    "frequencyWindowSeconds" => :frequency_window_seconds
  }

  def update(conn, %{"org_slug" => org_slug, "project_slug" => project_slug} = params) do
    with_project(conn, org_slug, project_slug, fn conn, project ->
      # частичное обновление: берём только присланные ключи (nil в значении —
      # осознанный сброс, например выключение порога частоты)
      attrs =
        for {json_key, field} <- @field_mapping,
            Map.has_key?(params, json_key),
            into: %{},
            do: {field, params[json_key]}

      case Alerts.upsert_settings(project.id, attrs) do
        {:ok, settings} ->
          json(conn, Serializer.alert_settings(settings, telegram_configured?()))

        {:error, changeset} ->
          conn |> put_status(400) |> json(%{detail: Serializer.changeset_detail(changeset)})
      end
    end)
  end

  defp telegram_configured? do
    token = Alerts.bot_token()
    is_binary(token) and token != ""
  end

  defp with_project(conn, org_slug, project_slug, fun) do
    with org when not is_nil(org) <- Projects.get_organization_by_slug(org_slug),
         true <- Swatter.Accounts.member?(conn.assigns.current_user, org.id),
         project when not is_nil(project) <- Projects.get_project_by_slug(org, project_slug) do
      fun.(conn, project)
    else
      _ -> conn |> put_status(404) |> json(%{detail: "project not found"})
    end
  end
end
