defmodule SwatterWeb.AuthControllerTest do
  use SwatterWeb.ConnCase, async: true

  import Swatter.AccountsFixtures
  import Swatter.ProjectsFixtures

  alias Swatter.Accounts

  describe "первый запуск" do
    test "setup требуется на пустой системе и исчезает после", %{conn: conn} do
      assert %{"setupRequired" => true} =
               conn |> get("/api/0/auth/setup") |> json_response(200)

      user_fixture()

      assert %{"setupRequired" => false} =
               conn |> get("/api/0/auth/setup") |> json_response(200)
    end

    test "создаёт owner-а с организацией и сразу логинит", %{conn: conn} do
      conn =
        post(conn, "/api/0/auth/setup", %{
          email: "admin@example.com",
          password: valid_password(),
          name: "Admin",
          orgName: "Acme",
          orgSlug: "acme"
        })

      body = json_response(conn, 200)
      assert body["email"] == "admin@example.com"
      assert [%{"role" => "owner", "organization" => %{"slug" => "acme"}}] = body["memberships"]

      # сессия установлена — /me работает без повторного логина
      assert conn |> get("/api/0/auth/me") |> json_response(200)
    end

    test "повторный setup → 403", %{conn: conn} do
      user_fixture()

      conn =
        post(conn, "/api/0/auth/setup", %{email: "x@example.com", password: valid_password()})

      assert json_response(conn, 403)
    end

    test "валидация: короткий пароль → 400", %{conn: conn} do
      conn = post(conn, "/api/0/auth/setup", %{email: "x@example.com", password: "short"})
      assert %{"detail" => detail} = json_response(conn, 400)
      assert detail =~ "password"
    end
  end

  describe "login / logout / me" do
    setup %{conn: conn} do
      user = user_fixture(%{"email" => "dev@example.com"})
      %{conn: conn, user: user}
    end

    test "успешный логин ставит сессию", %{conn: conn} do
      conn =
        post(conn, "/api/0/auth/login", %{email: "dev@example.com", password: valid_password()})

      assert %{"email" => "dev@example.com"} = json_response(conn, 200)
      assert %{"email" => "dev@example.com"} = conn |> get("/api/0/auth/me") |> json_response(200)
    end

    test "email нечувствителен к регистру", %{conn: conn} do
      conn =
        post(conn, "/api/0/auth/login", %{email: "DEV@example.com", password: valid_password()})

      assert json_response(conn, 200)
    end

    test "неверный пароль и неизвестный email → 401", %{conn: conn} do
      assert conn
             |> post("/api/0/auth/login", %{email: "dev@example.com", password: "wrong password"})
             |> json_response(401)

      assert conn
             |> post("/api/0/auth/login", %{
               email: "ghost@example.com",
               password: valid_password()
             })
             |> json_response(401)
    end

    test "logout ревокует токен", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)
      assert conn |> get("/api/0/auth/me") |> json_response(200)

      conn = post(conn, "/api/0/auth/logout")
      assert response(conn, 204)

      # токенов больше нет — даже старый cookie бесполезен
      assert Accounts.get_user_by_session_token(
               Plug.Conn.get_session(conn, :user_token) || "gone"
             ) == nil
    end

    test "me со списком организаций", %{conn: conn, user: user} do
      org = org_fixture()
      {:ok, _} = Accounts.add_member(user, org, "admin")

      body = conn |> log_in_user(user) |> get("/api/0/auth/me") |> json_response(200)
      assert [%{"role" => "admin", "organization" => %{"slug" => slug}}] = body["memberships"]
      assert slug == org.slug
    end
  end

  describe "защита API" do
    test "ресурсные endpoints без сессии → 401", %{conn: conn} do
      assert conn |> get("/api/0/organizations") |> json_response(401)
      assert conn |> get("/api/0/issues/1") |> json_response(401)
      assert conn |> put("/api/0/issues/1", %{status: "resolved"}) |> json_response(401)
      assert conn |> get("/api/0/auth/me") |> json_response(401)
    end

    test "истёкший/мусорный токен в сессии → 401", %{conn: conn} do
      conn = Plug.Test.init_test_session(conn, %{user_token: "garbage"})
      assert conn |> get("/api/0/organizations") |> json_response(401)
    end

    test "openapi.json остаётся публичным", %{conn: conn} do
      assert conn |> get("/api/0/openapi.json") |> json_response(200)
    end

    test "/health публичен и не требует хранилищ", %{conn: conn} do
      assert %{"status" => "ok"} = conn |> get("/health") |> json_response(200)
    end

    test "SPA-фолбэк без собранной SPA отвечает 404 с подсказкой", %{conn: conn} do
      assert %{"detail" => detail} = conn |> get("/some/spa/route") |> json_response(404)
      assert detail =~ "Vite"
    end
  end
end
