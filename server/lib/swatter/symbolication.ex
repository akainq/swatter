defmodule Swatter.Symbolication do
  @moduledoc """
  JS-символикация события по Debug IDs (ADR-0011): минифицированные фреймы
  разворачиваются в исходные позиции по sourcemap, найденному через
  `debug_meta.images[].debug_id`. Best-effort: без карты/совпадения фрейм
  остаётся как есть.

  Работает над сырым событием ДО нормализации — чтобы fingerprint (ADR-0006)
  считался по развёрнутому стеку.
  """

  alias Swatter.Symbolication.{Cache, SourceMap}

  @spec symbolicate(map(), pos_integer()) :: map()
  def symbolicate(event, project_id) when is_map(event) do
    images = debug_images(event)

    if images == %{} do
      event
    else
      symbolicate_exceptions(event, project_id, images)
    end
  end

  # code_file → debug_id из debug_meta.images (только sourcemap-образы)
  defp debug_images(event) do
    case get_in(event, ["debug_meta", "images"]) do
      images when is_list(images) ->
        images
        |> Enum.filter(&(is_map(&1) and is_binary(&1["debug_id"])))
        |> Map.new(fn img -> {img["code_file"] || img["code_id"] || :any, img["debug_id"]} end)

      _ ->
        %{}
    end
  end

  defp symbolicate_exceptions(event, project_id, images) do
    case Swatter.Pipeline.Fingerprint.exception_values(event) do
      [] ->
        event

      values ->
        new_values = Enum.map(values, &symbolicate_value(&1, project_id, images))
        put_in_exception(event, new_values)
    end
  end

  # exception может быть {"values": [...]} или голым списком (sentry-go)
  defp put_in_exception(%{"exception" => %{"values" => _}} = event, values) do
    put_in(event, ["exception", "values"], values)
  end

  defp put_in_exception(%{"exception" => list} = event, values) when is_list(list) do
    Map.put(event, "exception", values)
  end

  defp symbolicate_value(%{"stacktrace" => %{"frames" => frames}} = value, project_id, images)
       when is_list(frames) do
    put_in(
      value,
      ["stacktrace", "frames"],
      Enum.map(frames, &symbolicate_frame(&1, project_id, images))
    )
  end

  defp symbolicate_value(value, _project_id, _images), do: value

  defp symbolicate_frame(frame, project_id, images) when is_map(frame) do
    with debug_id when is_binary(debug_id) <- debug_id_for(frame, images),
         lineno when is_integer(lineno) <- frame["lineno"],
         %SourceMap{} = sm <- Cache.fetch(project_id, debug_id),
         %{source: source} = mapping when is_binary(source) <-
           SourceMap.lookup(sm, lineno, frame["colno"]) do
      apply_mapping(frame, mapping)
    else
      _ -> frame
    end
  end

  defp symbolicate_frame(frame, _project_id, _images), do: frame

  # debug_id для фрейма: по code_file == abs_path/filename; если образ один
  # и без code_file — берём его (:any)
  defp debug_id_for(frame, images) do
    file = frame["abs_path"] || frame["filename"]

    cond do
      is_binary(file) and Map.has_key?(images, file) -> images[file]
      Map.has_key?(images, :any) -> images[:any]
      map_size(images) == 1 -> images |> Map.values() |> List.first()
      true -> nil
    end
  end

  defp apply_mapping(frame, mapping) do
    frame
    |> Map.merge(%{
      "filename" => mapping.source || frame["filename"],
      "abs_path" => mapping.source || frame["abs_path"],
      "lineno" => mapping.line,
      "colno" => mapping.column,
      "in_app" => in_app?(mapping.source)
    })
    |> maybe_put_function(mapping.name)
    |> maybe_put_context(mapping.context)
    |> put_in([Access.key("data", %{}), "symbolicated"], true)
  end

  defp maybe_put_function(frame, nil), do: frame
  defp maybe_put_function(frame, name), do: Map.put(frame, "function", name)

  defp maybe_put_context(frame, nil), do: frame

  defp maybe_put_context(frame, %{"pre" => pre, "line" => line, "post" => post}) do
    frame
    |> Map.put("pre_context", pre)
    |> Map.put("context_line", line)
    |> Map.put("post_context", post)
  end

  # исходники вне node_modules считаем in-app (грубая эвристика, как у Sentry)
  defp in_app?(source) when is_binary(source), do: not String.contains?(source, "node_modules")
  defp in_app?(_), do: true
end
