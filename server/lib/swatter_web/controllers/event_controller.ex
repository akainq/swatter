defmodule SwatterWeb.EventController do
  use SwatterWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Swatter.{Events, Issues}
  alias SwatterWeb.{ApiSchemas, Serializer}

  tags(["events"])

  operation(:index,
    summary: "События issue (новые сверху)",
    parameters: [
      issue_id: [in: :path, type: :integer, required: true],
      cursor: [in: :query, type: :string],
      limit: [in: :query, schema: %OpenApiSpex.Schema{type: :integer, default: 50, maximum: 100}]
    ],
    responses: [
      ok: {"События", "application/json", ApiSchemas.EventList},
      bad_request: {"Некорректный курсор", "application/json", ApiSchemas.Error},
      not_found: {"Issue не найден", "application/json", ApiSchemas.Error}
    ]
  )

  def index(conn, %{"issue_id" => issue_id} = params) do
    case fetch_issue(conn, issue_id) do
      nil ->
        conn |> put_status(404) |> json(%{detail: "issue not found"})

      issue ->
        opts = [cursor: params["cursor"], limit: parse_limit(params["limit"])]

        case Events.list_events(issue.id, opts) do
          {:ok, events, next_cursor} ->
            conn
            |> put_next_link(next_cursor)
            |> json(Enum.map(events, &Serializer.event/1))

          {:error, :invalid_cursor} ->
            conn |> put_status(400) |> json(%{detail: "invalid cursor"})
        end
    end
  end

  operation(:latest,
    summary: "Последнее событие issue (для деталки со стектрейсом)",
    parameters: [issue_id: [in: :path, type: :integer, required: true]],
    responses: [
      ok: {"Событие", "application/json", ApiSchemas.Event},
      not_found: {"Не найдено", "application/json", ApiSchemas.Error}
    ]
  )

  def latest(conn, %{"issue_id" => issue_id}) do
    with issue when not is_nil(issue) <- fetch_issue(conn, issue_id),
         event when not is_nil(event) <- Events.latest_event(issue.id) do
      json(conn, Serializer.event(event))
    else
      nil -> conn |> put_status(404) |> json(%{detail: "not found"})
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
