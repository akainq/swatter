defmodule SwatterWeb.Plugs.IngestCORS do
  @moduledoc """
  CORS для ingest-эндпоинтов: браузерные Sentry SDK шлют envelope
  cross-origin. Sentry разрешает любой origin — делаем так же.
  """

  @behaviour Plug

  import Plug.Conn

  @headers [
    {"access-control-allow-origin", "*"},
    {"access-control-allow-methods", "POST, OPTIONS"},
    {"access-control-allow-headers",
     "accept, content-type, content-encoding, x-sentry-auth, sentry-trace, baggage"},
    {"access-control-expose-headers", "x-sentry-rate-limits, retry-after"},
    {"access-control-max-age", "3600"}
  ]

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    conn = merge_resp_headers(conn, @headers)

    if conn.method == "OPTIONS" do
      conn |> send_resp(204, "") |> halt()
    else
      conn
    end
  end
end
