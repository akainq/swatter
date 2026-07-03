defmodule Swatter.Pipeline.SpanBuilder do
  @moduledoc """
  Превращает `transaction`-item протокола Sentry в строки таблицы `spans`
  (ADR-0014): корневой span транзакции (`is_segment = 1`) + дочерние из
  `spans[]`. Все колонки CH не-Nullable — везде явные значения по умолчанию.

  Битые id (не hex нужной длины) — «ядовитый» контент: транзакция целиком
  (или отдельный span) дропается, retry не поможет.
  """

  @max_future_drift 60

  @doc "Список строк для insert_all или `[]`, если транзакция непригодна."
  @spec build(map(), map(), DateTime.t()) :: [map()]
  def build(tx, project, %DateTime{} = received_at) when is_map(tx) do
    trace_ctx = trace_context(tx)
    received_at = to_usec(received_at)

    with trace_id when is_binary(trace_id) <- hex_id(trace_ctx["trace_id"], 32),
         segment_id when is_binary(segment_id) <- hex_id(trace_ctx["span_id"], 16) do
      common = %{
        org_id: project.organization_id,
        project_id: project.id,
        trace_id: trace_id,
        segment_id: segment_id,
        transaction_name: str(tx["transaction"], "<unnamed>"),
        environment: str(tx["environment"], "production"),
        release: str(tx["release"]),
        platform: str(tx["platform"], "other"),
        tags: tx["tags"] |> normalize_tags() |> promote_server_name(tx),
        received_at: received_at
      }

      {start_ts, end_ts} = time_range(tx["start_timestamp"], tx["timestamp"], received_at)

      root =
        Map.merge(common, %{
          span_id: segment_id,
          parent_span_id: str(trace_ctx["parent_span_id"]),
          is_segment: 1,
          op: str(trace_ctx["op"]),
          description: common.transaction_name,
          status: str(trace_ctx["status"]),
          start_ts: start_ts,
          end_ts: end_ts,
          duration_ms: duration_ms(start_ts, end_ts)
        })

      [root | child_rows(tx["spans"], common, segment_id, received_at)]
    else
      _ -> []
    end
  end

  defp child_rows(spans, common, segment_id, received_at) when is_list(spans) do
    Enum.flat_map(spans, fn span ->
      with true <- is_map(span),
           span_id when is_binary(span_id) <- hex_id(span["span_id"], 16) do
        {start_ts, end_ts} =
          time_range(span["start_timestamp"], span["timestamp"], received_at)

        [
          Map.merge(common, %{
            span_id: span_id,
            parent_span_id: str(span["parent_span_id"], segment_id),
            is_segment: 0,
            op: str(span["op"]),
            description: str(span["description"]),
            status: str(span["status"]),
            start_ts: start_ts,
            end_ts: end_ts,
            duration_ms: duration_ms(start_ts, end_ts)
          })
        ]
      else
        _ -> []
      end
    end)
  end

  defp child_rows(_not_list, _common, _segment_id, _received_at), do: []

  defp trace_context(tx) do
    case get_in(tx, ["contexts", "trace"]) do
      ctx when is_map(ctx) -> ctx
      _ -> %{}
    end
  end

  # hex-id фиксированной длины (FixedString в CH): нормализуем и валидируем
  defp hex_id(value, length) when is_binary(value) do
    normalized = value |> String.replace("-", "") |> String.downcase()

    if byte_size(normalized) == length and normalized =~ ~r/^[0-9a-f]+$/ do
      normalized
    else
      nil
    end
  end

  defp hex_id(_, _), do: nil

  # start/end: числа (секунды) или ISO-строки; end не раньше start,
  # будущее прижимается к received_at (как в Normalizer)
  defp time_range(start_raw, end_raw, received_at) do
    start_ts = start_raw |> parse_timestamp(received_at) |> clamp_future(received_at)
    end_ts = end_raw |> parse_timestamp(start_ts) |> clamp_future(received_at)
    end_ts = if DateTime.compare(end_ts, start_ts) == :lt, do: start_ts, else: end_ts
    {to_usec(start_ts), to_usec(end_ts)}
  end

  defp duration_ms(start_ts, end_ts) do
    max(DateTime.diff(end_ts, start_ts, :microsecond) / 1000, 0.0)
  end

  defp parse_timestamp(ts, _fallback) when is_number(ts) do
    DateTime.from_unix!(round(ts * 1000), :millisecond)
  end

  defp parse_timestamp(ts, fallback) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _offset} -> dt
      _ -> fallback
    end
  end

  defp parse_timestamp(_, fallback), do: fallback

  defp clamp_future(dt, received_at) do
    if DateTime.diff(dt, received_at, :second) > @max_future_drift, do: received_at, else: dt
  end

  defp to_usec(%DateTime{microsecond: {us, _precision}} = dt), do: %{dt | microsecond: {us, 6}}

  defp normalize_tags(tags) when is_map(tags) do
    Map.new(tags, fn {k, v} -> {to_string(k), tag_value(v)} end)
  end

  defp normalize_tags(tags) when is_list(tags) do
    tags
    |> Enum.filter(&match?([_, _], &1))
    |> Map.new(fn [k, v] -> {to_string(k), tag_value(v)} end)
  end

  defp normalize_tags(_), do: %{}

  defp tag_value(nil), do: ""
  defp tag_value(v) when is_binary(v), do: truncate(v, 200)
  defp tag_value(v), do: v |> to_string() |> truncate(200)

  # как у ошибок (Normalizer): хост из top-level server_name — в теги
  defp promote_server_name(tags, tx) do
    case str(tx["server_name"]) do
      "" -> tags
      host -> Map.put_new(tags, "server_name", truncate(host, 200))
    end
  end

  defp str(value, default \\ "")
  defp str(nil, default), do: default
  defp str(value, _default) when is_binary(value), do: value
  defp str(value, _default) when is_number(value) or is_atom(value), do: to_string(value)
  defp str(_, default), do: default

  defp truncate(string, max) do
    if String.length(string) > max, do: String.slice(string, 0, max), else: string
  end
end
