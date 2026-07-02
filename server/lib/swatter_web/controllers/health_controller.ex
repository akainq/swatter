defmodule SwatterWeb.HealthController do
  @moduledoc """
  Liveness для docker/Coolify healthcheck: без auth и без обращений к
  хранилищам — «приложение поднялось». Глубокие проверки зависимостей —
  задача ADR-0015 (самомониторинг).
  """

  use SwatterWeb, :controller

  @doc false
  def open_api_operation(_action), do: nil

  def show(conn, _params) do
    json(conn, %{status: "ok"})
  end
end
