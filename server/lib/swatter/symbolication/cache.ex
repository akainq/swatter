defmodule Swatter.Symbolication.Cache do
  @moduledoc """
  ETS-кэш разобранных sourcemap по `{project_id, debug_id}` (ADR-0011):
  карта разбирается один раз, дальше переиспользуется.

  Загрузка (чтение из Postgres + разбор) выполняется в процессе-вызывателе
  (Broadway-процессор), а не в этом GenServer — чтобы Repo-доступ уважал
  sandbox в тестах. GenServer лишь владеет публичной ETS-таблицей.
  """

  use GenServer

  alias Swatter.Artifacts
  alias Swatter.Symbolication.SourceMap

  @table :swatter_source_maps

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @doc """
  Возвращает `%SourceMap{}` или nil. Промах кэша → чтение из Artifacts и
  разбор здесь же (в вызывающем процессе). Кэшируются только успешно
  разобранные карты (промах по БД остаётся промахом — карту могли ещё не
  загрузить).
  """
  def fetch(project_id, debug_id) do
    key = {project_id, Artifacts.normalize_debug_id(debug_id)}

    case :ets.lookup(@table, key) do
      [{^key, %SourceMap{} = sm}] ->
        sm

      _ ->
        load(project_id, debug_id, key)
    end
  end

  defp load(project_id, debug_id, key) do
    with content when is_binary(content) <- Artifacts.fetch_source_map(project_id, debug_id),
         {:ok, sm} <- SourceMap.parse(content) do
      # таблица может отсутствовать, если кэш не запущен (edge) — тогда без кэша
      if :ets.whereis(@table) != :undefined, do: :ets.insert(@table, {key, sm})
      sm
    else
      _ -> nil
    end
  end

  @doc "Сброс (тесты)."
  def clear do
    if :ets.whereis(@table) != :undefined, do: :ets.delete_all_objects(@table)
    :ok
  end
end
