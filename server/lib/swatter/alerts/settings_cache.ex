defmodule Swatter.Alerts.SettingsCache do
  @moduledoc """
  ETS-кэш per-project настроек алертов (ADR-0013). Частотное правило смотрит
  каждое событие — кэш убирает PG-чтение с горячего пути пайплайна.

  Загрузка из Postgres выполняется в процессе-вызывателе (как
  `Symbolication.Cache`), чтобы уважать sandbox в тестах; GenServer лишь
  владеет публичной ETS-таблицей. Запись настроек инвалидирует запись
  (`invalidate/1`), иначе — TTL.
  """

  use GenServer

  alias Swatter.Alerts.Settings
  alias Swatter.Repo

  @table :swatter_alert_settings
  @ttl_ms 30_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @doc "Настройки проекта из кэша (или загрузка в вызывателе с TTL)."
  def get(project_id) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, project_id) do
      [{^project_id, settings, expires_at}] when expires_at > now -> settings
      _ -> load(project_id, now)
    end
  end

  @doc "Сбросить запись проекта (после изменения настроек)."
  def invalidate(project_id) do
    if :ets.whereis(@table) != :undefined, do: :ets.delete(@table, project_id)
    :ok
  end

  @doc "Полный сброс (тесты)."
  def clear do
    if :ets.whereis(@table) != :undefined, do: :ets.delete_all_objects(@table)
    :ok
  end

  defp load(project_id, now) do
    settings = Repo.get_by(Settings, project_id: project_id) || %Settings{project_id: project_id}

    if :ets.whereis(@table) != :undefined,
      do: :ets.insert(@table, {project_id, settings, now + @ttl_ms})

    settings
  end
end
