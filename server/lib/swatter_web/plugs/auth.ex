defmodule SwatterWeb.Plugs.Auth do
  @moduledoc """
  Сессионная аутентификация dashboard API (ADR-0007).

  Cookie HttpOnly + SameSite=Lax (задан в endpoint) — Lax не отправляет
  cookie на cross-site POST/PUT, что закрывает CSRF для JSON-API без
  отдельного токена.
  """

  import Plug.Conn

  alias Swatter.Accounts

  @session_key :user_token

  def fetch_current_user(conn, _opts) do
    conn = fetch_session(conn)
    token = get_session(conn, @session_key)
    assign(conn, :current_user, token && Accounts.get_user_by_session_token(token))
  end

  def require_authenticated(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
    else
      conn
      |> put_status(401)
      |> Phoenix.Controller.json(%{detail: "authentication required"})
      |> halt()
    end
  end

  def log_in_user(conn, user) do
    token = Accounts.create_session_token(user)

    conn
    |> fetch_session()
    # renew_session против фиксации сессии
    |> configure_session(renew: true)
    |> put_session(@session_key, token)
    |> assign(:current_user, user)
  end

  def log_out_user(conn) do
    conn = fetch_session(conn)

    if token = get_session(conn, @session_key) do
      Accounts.delete_session_token(token)
    end

    conn
    |> configure_session(drop: true)
    |> assign(:current_user, nil)
  end

  def session_key, do: @session_key
end
