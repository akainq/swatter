defmodule Mix.Tasks.Swatter.ResetPassword do
  @shortdoc "Сбрасывает пароль пользователя: mix swatter.reset_password EMAIL"

  @moduledoc """
  Аварийный сброс пароля админом сервера (ADR-0007: восстановление без
  SMTP). Генерирует новый пароль, печатает его и ревокует все сессии
  пользователя.

      mix swatter.reset_password admin@example.com
  """

  use Mix.Task

  @impl Mix.Task
  def run([email]) do
    Mix.Task.run("app.start")

    case Swatter.Accounts.get_user_by_email(email) do
      nil ->
        Mix.raise("user #{email} not found")

      user ->
        password = 12 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

        case Swatter.Accounts.reset_password(user, password) do
          {:ok, _user} ->
            Mix.shell().info("""

              Новый пароль для #{email}: #{password}
              Все активные сессии пользователя завершены.
            """)

          {:error, changeset} ->
            Mix.raise("could not reset password: #{inspect(changeset.errors)}")
        end
    end
  end

  def run(_args), do: Mix.raise("usage: mix swatter.reset_password EMAIL")
end
