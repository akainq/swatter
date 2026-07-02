defmodule Swatter.Symbolication.SourceMap do
  @moduledoc """
  Разбор Source Map v3 и поиск исходной позиции по generated (ADR-0011).

  `mappings` — Base64 VLQ: строки-группы разделены `;` (generated-строки),
  внутри — сегменты через `,`. Поля сегмента (все дельты): generated-колонка
  (сбрасывается на каждой строке), индекс source, source-строка,
  source-колонка, индекс name (опционально). Остальные четыре — кумулятивны
  по всему mappings.
  """

  import Bitwise

  defstruct sources: [], names: [], sources_content: [], lines: %{}

  @b64 ~c"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  @b64_map @b64 |> Enum.with_index() |> Map.new()

  @type t :: %__MODULE__{}

  @spec parse(binary()) :: {:ok, t()} | :error
  def parse(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{"version" => 3, "mappings" => mappings} = map} when is_binary(mappings) ->
        {:ok,
         %__MODULE__{
           sources: List.wrap(map["sources"]),
           names: List.wrap(map["names"]),
           sources_content: List.wrap(map["sourcesContent"]),
           lines: decode_mappings(mappings)
         }}

      _ ->
        :error
    end
  end

  @doc """
  Ищет исходную позицию для generated (`line`/`column` 1-based, как в
  stacktrace). Возвращает `%{source, line, column, name, context}` или nil.
  `context` — `{pre_lines, context_line, post_lines}` из sourcesContent,
  если он есть.
  """
  def lookup(%__MODULE__{} = sm, line, column) when is_integer(line) do
    line0 = line - 1
    col0 = max((column || 1) - 1, 0)

    with segments when is_list(segments) <- Map.get(sm.lines, line0),
         {_gc, src_idx, src_line, src_col, name_idx} <- best_segment(segments, col0) do
      %{
        source: Enum.at(sm.sources, src_idx),
        line: src_line + 1,
        column: src_col + 1,
        name: name_idx && Enum.at(sm.names, name_idx),
        context: context_lines(sm, src_idx, src_line)
      }
    else
      _ -> nil
    end
  end

  def lookup(_sm, _line, _column), do: nil

  # последний сегмент с gen_col <= col0 (сегменты отсортированы по gen_col)
  defp best_segment(segments, col0) do
    Enum.reduce(segments, nil, fn {gc, _, _, _, _} = seg, acc ->
      if gc <= col0, do: seg, else: acc
    end) || List.first(segments)
  end

  defp context_lines(%__MODULE__{sources_content: content}, src_idx, src_line) do
    case Enum.at(content, src_idx) do
      source when is_binary(source) ->
        lines = String.split(source, "\n")
        pre = lines |> Enum.slice(max(src_line - 5, 0), min(src_line, 5))
        ctx = Enum.at(lines, src_line)
        post = Enum.slice(lines, src_line + 1, 5)
        %{"pre" => pre, "line" => ctx, "post" => post}

      _ ->
        nil
    end
  end

  ## декодирование mappings

  defp decode_mappings(mappings) do
    mappings
    |> String.split(";")
    |> Enum.with_index()
    |> Enum.reduce({%{}, {0, 0, 0, 0}}, fn {line_str, idx}, {acc, carry} ->
      {segments, carry} = decode_line(line_str, carry)
      acc = if segments == [], do: acc, else: Map.put(acc, idx, Enum.reverse(segments))
      {acc, carry}
    end)
    |> elem(0)
  end

  # gen_col стартует с 0 на каждой строке; carry = {src, sline, scol, name}
  defp decode_line("", carry), do: {[], carry}

  defp decode_line(line_str, carry) do
    line_str
    |> String.split(",")
    |> Enum.reduce({[], 0, carry}, fn seg_str, {segs, gen_col, {src, sline, scol, name}} ->
      case decode_vlqs(String.to_charlist(seg_str)) do
        [gc] ->
          {segs, gen_col + gc, {src, sline, scol, name}}

        [gc, si, sl, sc] ->
          gen_col = gen_col + gc
          src = src + si
          sline = sline + sl
          scol = scol + sc
          {[{gen_col, src, sline, scol, nil} | segs], gen_col, {src, sline, scol, name}}

        [gc, si, sl, sc, ni] ->
          gen_col = gen_col + gc
          src = src + si
          sline = sline + sl
          scol = scol + sc
          name = name + ni
          {[{gen_col, src, sline, scol, name} | segs], gen_col, {src, sline, scol, name}}

        _ ->
          {segs, gen_col, {src, sline, scol, name}}
      end
    end)
    |> then(fn {segs, _gen_col, carry} -> {segs, carry} end)
  end

  defp decode_vlqs(chars), do: decode_vlqs(chars, [])

  defp decode_vlqs([], acc), do: Enum.reverse(acc)

  defp decode_vlqs(chars, acc) do
    {value, rest} = decode_vlq(chars, 0, 0)
    decode_vlqs(rest, [value | acc])
  end

  defp decode_vlq([c | rest], shift, acc) do
    digit = Map.fetch!(@b64_map, c)
    acc = acc + ((digit &&& 31) <<< shift)

    if (digit &&& 32) != 0 do
      decode_vlq(rest, shift + 5, acc)
    else
      value = acc >>> 1
      {if((acc &&& 1) == 1, do: -value, else: value), rest}
    end
  end
end
