defmodule Swatter.Artifacts do
  @moduledoc """
  Хранилище sourcemap-артефактов (ADR-0012): контент gzip-сжат в PG,
  матчинг символикатором по `(project, debug_id, type)`.
  """

  import Ecto.Query

  alias Swatter.Artifacts.ArtifactBundle
  alias Swatter.Repo

  @doc """
  Сохраняет артефакт (идемпотентно по project+debug_id+type: повтор
  заменяет контент). `debug_id` нормализуется к нижнему регистру без
  дефисов — как в debug_meta событий.
  """
  def put(project_id, debug_id, type, content, name \\ nil)
      when type in ~w(source_map minified_source) and is_binary(content) do
    compressed = :zlib.gzip(content)
    now = DateTime.utc_now()

    %ArtifactBundle{
      project_id: project_id,
      debug_id: normalize_debug_id(debug_id),
      type: type,
      name: name,
      content: compressed,
      content_size: byte_size(content),
      compressed_size: byte_size(compressed)
    }
    |> Repo.insert(
      on_conflict: [
        set: [
          content: compressed,
          content_size: byte_size(content),
          compressed_size: byte_size(compressed),
          name: name,
          updated_at: now
        ]
      ],
      conflict_target: [:project_id, :debug_id, :type],
      returning: true
    )
  end

  @doc "Распакованный контент source_map по debug_id или nil."
  def fetch_source_map(project_id, debug_id) do
    fetch(project_id, debug_id, "source_map")
  end

  def fetch(project_id, debug_id, type) do
    query =
      from a in ArtifactBundle,
        where:
          a.project_id == ^project_id and a.debug_id == ^normalize_debug_id(debug_id) and
            a.type == ^type,
        select: a.content

    case Repo.one(query) do
      nil -> nil
      compressed -> :zlib.gunzip(compressed)
    end
  end

  def normalize_debug_id(debug_id) when is_binary(debug_id) do
    debug_id |> String.replace("-", "") |> String.downcase()
  end
end
