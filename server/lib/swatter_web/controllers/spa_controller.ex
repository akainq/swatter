defmodule SwatterWeb.SPAController do
  @moduledoc """
  Фолбэк клиентского роутинга: любые не-API GET отдают index.html
  собранной SPA (ADR-0007: same-origin). Хэшированные ассеты отдаёт
  Plug.Static; сам index.html — всегда без кэша, чтобы деплой новой
  версии подхватывался сразу.
  """

  use SwatterWeb, :controller

  @doc false
  def open_api_operation(_action), do: nil

  def index(conn, _params) do
    index_path = Application.app_dir(:swatter, "priv/static/index.html")

    if File.exists?(index_path) do
      conn
      |> put_resp_header("cache-control", "no-cache, no-store, must-revalidate")
      |> put_resp_content_type("text/html")
      |> send_file(200, index_path)
    else
      # dev без собранной SPA (фронт живёт на Vite) — честный 404
      conn
      |> put_status(404)
      |> json(%{detail: "SPA is not built; in dev use the Vite server (web/: bun dev)"})
    end
  end
end
