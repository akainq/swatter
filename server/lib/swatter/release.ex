defmodule Swatter.Release do
  @moduledoc """
  Задачи релиза (mix release не включает Mix). Миграции обоих
  репозиториев (PG + ClickHouse) выполняются на старте контейнера —
  ADR-0004: автомиграции, только additive-схемы между соседними версиями.

      bin/swatter eval "Swatter.Release.migrate()"
  """

  @app :swatter

  def migrate do
    Application.load(@app)

    for repo <- Application.fetch_env!(@app, :ecto_repos) do
      {:ok, _fun_return, _apps} =
        Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    :ok
  end

  @doc """
  Аварийный сброс пароля в релизе (mix-задач там нет). Вызывается на
  живой ноде: `bin/swatter rpc 'Swatter.Release.reset_password("a@b.c")'`.
  Печатает новый пароль и ревокует все сессии пользователя.
  """
  def reset_password(email) do
    case Swatter.Accounts.get_user_by_email(email) do
      nil ->
        IO.puts("user #{email} not found")
        :error

      user ->
        password = 12 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
        {:ok, _} = Swatter.Accounts.reset_password(user, password)
        IO.puts("New password for #{email}: #{password}")
        :ok
    end
  end
end
