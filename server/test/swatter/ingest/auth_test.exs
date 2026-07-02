defmodule Swatter.Ingest.AuthTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias Swatter.Ingest.Auth

  @key "abcdef0123456789abcdef0123456789"

  test "разбирает X-Sentry-Auth со всеми полями" do
    conn =
      conn(:post, "/api/1/envelope")
      |> put_req_header(
        "x-sentry-auth",
        "Sentry sentry_version=7, sentry_client=sentry.javascript.bun/10.0.0, sentry_key=#{@key}"
      )

    assert {:ok, auth} = Auth.from_conn(conn)
    assert auth.public_key == @key
    assert auth.client == "sentry.javascript.bun/10.0.0"
    assert auth.version == "7"
  end

  test "принимает строчный префикс sentry" do
    conn =
      conn(:post, "/")
      |> put_req_header("x-sentry-auth", "sentry sentry_key=#{@key}")

    assert {:ok, %{public_key: @key}} = Auth.from_conn(conn)
  end

  test "игнорирует sentry_secret (deprecated)" do
    conn =
      conn(:post, "/")
      |> put_req_header("x-sentry-auth", "Sentry sentry_key=#{@key},sentry_secret=shhh")

    assert {:ok, %{public_key: @key}} = Auth.from_conn(conn)
  end

  test "берёт ключ из query-параметра, когда заголовка нет" do
    assert {:ok, %{public_key: @key}} = Auth.from_conn(conn(:post, "/?sentry_key=#{@key}"))
  end

  test "заголовок приоритетнее query-параметра" do
    conn =
      conn(:post, "/?sentry_key=fromquery")
      |> put_req_header("x-sentry-auth", "Sentry sentry_key=#{@key}")

    assert {:ok, %{public_key: @key}} = Auth.from_conn(conn)
  end

  test "ошибка без ключа" do
    assert {:error, :missing_auth} = Auth.from_conn(conn(:post, "/"))

    conn = conn(:post, "/") |> put_req_header("x-sentry-auth", "Sentry sentry_version=7")
    assert {:error, :missing_auth} = Auth.from_conn(conn)

    conn = conn(:post, "/") |> put_req_header("x-sentry-auth", "Basic dXNlcjpwYXNz")
    assert {:error, :missing_auth} = Auth.from_conn(conn)
  end
end
