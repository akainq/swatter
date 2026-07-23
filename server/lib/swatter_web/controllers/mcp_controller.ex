defmodule SwatterWeb.MCPController do
  @moduledoc """
  MCP-сервер (ADR-0017): Streamable HTTP = JSON-RPC 2.0 поверх POST, ответы —
  обычный `application/json` (SSE не предлагаем, спека это допускает).
  Stateless: сессии не выдаются. Авторизация — Bearer `swt_*` (API-токен).

  Подключение из Claude Code:
      claude mcp add --transport http swatter https://host/mcp \\
        --header "Authorization: Bearer swt_..."
  """

  use SwatterWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Swatter.Accounts
  alias Swatter.MCP.Tools

  # новейшая — первой: её предлагаем, если клиент просит неизвестную версию
  @protocol_versions ["2025-06-18", "2025-03-26", "2024-11-05"]

  operation(:handle, false)
  operation(:method_not_allowed, false)

  def handle(conn, _params) do
    case authenticate(conn) do
      {:ok, user} -> dispatch(conn, conn.body_params, user)
      :error -> unauthorized(conn)
    end
  end

  # GET /mcp — SSE-стрим не поддерживаем (stateless-сервер)
  def method_not_allowed(conn, _params) do
    conn
    |> put_resp_header("allow", "POST")
    |> send_resp(405, "")
  end

  defp authenticate(conn) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         %{} = user <- Accounts.get_user_by_api_token(String.trim(token)) do
      {:ok, user}
    else
      _ -> :error
    end
  end

  defp unauthorized(conn) do
    conn
    |> put_resp_header("www-authenticate", "Bearer")
    |> put_status(401)
    |> json(%{error: "unauthorized: pass a Swatter API token (swt_...) as a Bearer header"})
  end

  ## JSON-RPC dispatch

  defp dispatch(conn, %{"jsonrpc" => "2.0", "method" => method} = msg, user) do
    id = Map.get(msg, "id")
    params = Map.get(msg, "params") || %{}

    cond do
      # уведомления ответа не требуют (в т.ч. notifications/initialized)
      is_nil(id) ->
        send_resp(conn, 202, "")

      method == "initialize" ->
        reply(conn, id, initialize_result(params))

      method == "ping" ->
        reply(conn, id, %{})

      method == "tools/list" ->
        reply(conn, id, %{tools: Tools.list()})

      method == "tools/call" ->
        tool_call(conn, id, params, user)

      true ->
        reply_error(conn, id, -32601, "method not found: #{method}")
    end
  end

  # батчи убраны в MCP 2025-06-18; всё остальное — не JSON-RPC
  defp dispatch(conn, _body, _user) do
    reply_error(conn, nil, -32600, "invalid request: expected a single JSON-RPC 2.0 message")
  end

  defp initialize_result(params) do
    requested = params["protocolVersion"]

    version =
      if requested in @protocol_versions, do: requested, else: hd(@protocol_versions)

    %{
      protocolVersion: version,
      capabilities: %{tools: %{}},
      serverInfo: %{
        name: "swatter",
        version: to_string(Application.spec(:swatter, :vsn) || "dev")
      }
    }
  end

  defp tool_call(conn, id, params, user) do
    name = params["name"]
    args = params["arguments"] || %{}

    if is_binary(name) and Enum.any?(Tools.list(), &(&1.name == name)) do
      {text, error?} =
        case Tools.call(name, args, user) do
          {:ok, text} -> {text, false}
          {:error, text} -> {text, true}
        end

      reply(conn, id, %{content: [%{type: "text", text: text}], isError: error?})
    else
      reply_error(conn, id, -32602, "unknown tool: #{inspect(name)}")
    end
  end

  defp reply(conn, id, result) do
    json(conn, %{jsonrpc: "2.0", id: id, result: result})
  end

  defp reply_error(conn, id, code, message) do
    json(conn, %{jsonrpc: "2.0", id: id, error: %{code: code, message: message}})
  end
end
