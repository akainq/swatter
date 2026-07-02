defmodule Swatter.Alerts.Telegram do
  @moduledoc """
  Отправка сообщений через Telegram Bot API (ADR-0013) — `sendMessage`,
  plain text (без Markdown, чтобы спецсимволы в title не ломали доставку),
  через `Req`. HTTP-транспорт в тестах подменяется `Req.Test` (`:req_options`).
  """

  alias Swatter.Alerts

  @spec send_message(String.t() | nil, String.t()) :: :ok | {:error, term()}
  def send_message(chat_id, text) do
    token = Alerts.bot_token()

    cond do
      is_nil(token) or token == "" -> {:error, :no_token}
      is_nil(chat_id) or chat_id == "" -> {:error, :no_chat_id}
      true -> do_send(token, chat_id, text)
    end
  end

  defp do_send(token, chat_id, text) do
    url = "#{api_base()}/bot#{token}/sendMessage"
    body = %{chat_id: chat_id, text: text, disable_web_page_preview: true}

    case Req.post([url: url, json: body, receive_timeout: 15_000] ++ req_options()) do
      {:ok, %Req.Response{status: status, body: %{"ok" => true}}} when status in 200..299 ->
        :ok

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp cfg, do: Application.get_env(:swatter, :alerts, [])
  defp api_base, do: cfg()[:telegram_api_base] || "https://api.telegram.org"
  defp req_options, do: cfg()[:req_options] || []
end
