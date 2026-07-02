defmodule SwatterWeb.AuthController do
  use SwatterWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Swatter.Accounts
  alias SwatterWeb.{ApiSchemas, Serializer}
  alias SwatterWeb.Plugs.Auth

  tags(["auth"])

  operation(:setup_status,
    summary: "Нужен ли первый запуск (в системе нет пользователей)",
    responses: [ok: {"Статус", "application/json", ApiSchemas.SetupStatus}]
  )

  def setup_status(conn, _params) do
    json(conn, %{setupRequired: Accounts.setup_required?()})
  end

  operation(:setup,
    summary: "Первый запуск: создать owner-пользователя и организацию",
    request_body: {"Данные владельца", "application/json", ApiSchemas.SetupRequest},
    responses: [
      ok: {"Созданный пользователь", "application/json", ApiSchemas.CurrentUser},
      bad_request: {"Ошибка валидации", "application/json", ApiSchemas.Error},
      forbidden: {"Система уже настроена", "application/json", ApiSchemas.Error}
    ]
  )

  def setup(conn, params) do
    case Accounts.bootstrap(params) do
      {:ok, user, _org} ->
        conn |> Auth.log_in_user(user) |> me(%{})

      {:error, :already_set_up} ->
        conn |> put_status(403) |> json(%{detail: "already set up"})

      {:error, changeset} ->
        conn |> put_status(400) |> json(%{detail: Serializer.changeset_detail(changeset)})
    end
  end

  operation(:login,
    summary: "Вход по email и паролю (устанавливает сессионный cookie)",
    request_body: {"Учётные данные", "application/json", ApiSchemas.LoginRequest},
    responses: [
      ok: {"Текущий пользователь", "application/json", ApiSchemas.CurrentUser},
      unauthorized: {"Неверные данные", "application/json", ApiSchemas.Error}
    ]
  )

  def login(conn, %{"email" => email, "password" => password})
      when is_binary(email) and is_binary(password) do
    case Accounts.get_user_by_email_and_password(email, password) do
      nil ->
        conn |> put_status(401) |> json(%{detail: "invalid email or password"})

      user ->
        conn |> Auth.log_in_user(user) |> me(%{})
    end
  end

  def login(conn, _params) do
    conn |> put_status(401) |> json(%{detail: "invalid email or password"})
  end

  operation(:logout,
    summary: "Выход (ревокация сессионного токена)",
    responses: [no_content: "Сессия завершена"]
  )

  def logout(conn, _params) do
    conn |> Auth.log_out_user() |> send_resp(204, "")
  end

  operation(:me,
    summary: "Текущий пользователь и его организации",
    responses: [
      ok: {"Пользователь", "application/json", ApiSchemas.CurrentUser},
      unauthorized: {"Не аутентифицирован", "application/json", ApiSchemas.Error}
    ]
  )

  def me(conn, _params) do
    user = conn.assigns.current_user
    json(conn, Serializer.current_user(user, Accounts.list_memberships(user)))
  end
end
