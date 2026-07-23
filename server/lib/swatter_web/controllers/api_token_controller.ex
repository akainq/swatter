defmodule SwatterWeb.ApiTokenController do
  use SwatterWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Swatter.Accounts
  alias SwatterWeb.ApiSchemas

  tags(["api-tokens"])

  operation(:index,
    summary: "API-токены текущего пользователя (ADR-0017, без секретов)",
    responses: [ok: {"Токены", "application/json", ApiSchemas.ApiTokenList}]
  )

  def index(conn, _params) do
    tokens = Accounts.list_api_tokens(conn.assigns.current_user)
    json(conn, Enum.map(tokens, &serialize/1))
  end

  operation(:create,
    summary: "Создать API-токен (плейнтекст возвращается один раз)",
    request_body: {"Имя токена", "application/json", ApiSchemas.ApiTokenCreateRequest},
    responses: [
      created: {"Создан", "application/json", ApiSchemas.ApiTokenCreated},
      bad_request: {"Ошибка", "application/json", ApiSchemas.Error}
    ]
  )

  def create(conn, params) do
    name = params["name"] |> to_string() |> String.trim()

    case Accounts.create_api_token(conn.assigns.current_user, name) do
      {:ok, plaintext, record} ->
        conn |> put_status(201) |> json(record |> serialize() |> Map.put("token", plaintext))

      {:error, :invalid_name} ->
        conn |> put_status(400) |> json(%{detail: "name is required"})
    end
  end

  operation(:delete,
    summary: "Отозвать API-токен",
    parameters: [id: [in: :path, type: :integer, required: true]],
    responses: [
      no_content: "Отозван",
      not_found: {"Не найден", "application/json", ApiSchemas.Error}
    ]
  )

  def delete(conn, %{"id" => id}) do
    with {token_id, ""} <- Integer.parse(to_string(id)),
         {:ok, _} <- Accounts.delete_api_token(conn.assigns.current_user, token_id) do
      send_resp(conn, 204, "")
    else
      _ -> conn |> put_status(404) |> json(%{detail: "token not found"})
    end
  end

  defp serialize(token) do
    %{
      "id" => to_string(token.id),
      "name" => token.name,
      "insertedAt" => DateTime.to_iso8601(token.inserted_at)
    }
  end
end
