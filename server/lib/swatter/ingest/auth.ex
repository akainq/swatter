defmodule Swatter.Ingest.Auth do
  @moduledoc """
  Аутентификация ingest-запроса по протоколу Sentry (ADR-0001).

  Публичный ключ приходит либо в заголовке
  `X-Sentry-Auth: Sentry sentry_version=7, sentry_key=<key>, sentry_client=<client>`,
  либо в query-параметре `?sentry_key=<key>` (браузерные SDK, tunnel).
  Секретный ключ (sentry_secret) устарел и игнорируется.
  """

  import Plug.Conn, only: [get_req_header: 2]

  defstruct [:public_key, :client, :version]

  @type t :: %__MODULE__{public_key: String.t(), client: String.t() | nil}

  @spec from_conn(Plug.Conn.t()) :: {:ok, t()} | {:error, :missing_auth}
  def from_conn(conn) do
    case get_req_header(conn, "x-sentry-auth") do
      [header | _] -> from_header(header)
      [] -> from_query(conn)
    end
  end

  defp from_header("Sentry " <> pairs), do: parse_pairs(pairs)
  defp from_header("sentry " <> pairs), do: parse_pairs(pairs)
  defp from_header(_), do: {:error, :missing_auth}

  defp parse_pairs(pairs) do
    parsed =
      pairs
      |> String.split(",")
      |> Enum.reduce(%{}, fn pair, acc ->
        case String.split(String.trim(pair), "=", parts: 2) do
          [k, v] -> Map.put(acc, String.trim(k), String.trim(v))
          _ -> acc
        end
      end)

    case parsed do
      %{"sentry_key" => key} when key != "" ->
        {:ok,
         %__MODULE__{
           public_key: key,
           client: parsed["sentry_client"],
           version: parsed["sentry_version"]
         }}

      _ ->
        {:error, :missing_auth}
    end
  end

  defp from_query(conn) do
    case Plug.Conn.fetch_query_params(conn).query_params do
      %{"sentry_key" => key} when is_binary(key) and key != "" ->
        {:ok, %__MODULE__{public_key: key, client: nil, version: nil}}

      _ ->
        {:error, :missing_auth}
    end
  end
end
