defmodule Swatter.AI.ZAI do
  @moduledoc """
  Транспорт к z.ai (ADR-0016): OpenAI-совместимый `POST /chat/completions`
  через `Req`. Модель/ключ/URL — из runtime-конфига `:swatter, :ai`
  (`ZAI_API_KEY`, `ZAI_MODEL`, `ZAI_BASE_URL`). В тестах HTTP подменяется
  `Req.Test` через `:req_options`.

  `response_format: json_object` — просим модель отвечать строгим JSON;
  разбор ответа — на вызывающей стороне (`Swatter.AI.parse_result/1`).
  """

  @max_response_tokens 800

  @doc "Строка модели из конфига (пишется в результат анализа)."
  def model, do: cfg()[:model] || "glm-4.6"

  @spec chat([map()]) :: {:ok, String.t()} | {:error, term()}
  def chat(messages) do
    key = cfg()[:api_key]

    if key in [nil, ""] do
      {:error, :no_api_key}
    else
      request(key, messages)
    end
  end

  defp request(key, messages) do
    opts =
      [
        url: "#{base_url()}/chat/completions",
        auth: {:bearer, key},
        receive_timeout: cfg()[:timeout_ms] || 60_000,
        json: %{
          model: model(),
          messages: messages,
          response_format: %{type: "json_object"},
          max_tokens: @max_response_tokens
        }
      ] ++ (cfg()[:req_options] || [])

    case Req.post(opts) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        case get_in(body, ["choices", Access.at(0), "message", "content"]) do
          content when is_binary(content) and content != "" -> {:ok, content}
          _ -> {:error, :empty_response}
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp base_url, do: cfg()[:base_url] || "https://api.z.ai/api/paas/v4"
  defp cfg, do: Application.get_env(:swatter, :ai, [])
end
