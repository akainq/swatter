defmodule Swatter.Pipeline.Normalizer do
  @moduledoc """
  Нормализация события Sentry в плоскую структуру: поля строки ClickHouse
  (`Swatter.Events.Event`) + атрибуты для issue (title, culprit,
  fingerprint). Все колонки CH не-Nullable — везде явные значения по
  умолчанию.
  """

  alias Swatter.Ingest.Envelope
  alias Swatter.Pipeline.Fingerprint

  # секунд в будущее, дальше которых timestamp клиента не верим
  @max_future_drift 60

  @spec normalize(map(), DateTime.t()) :: map()
  def normalize(event, %DateTime{} = received_at) when is_map(event) do
    exception = primary_exception(event)
    received_at = to_usec(received_at)

    timestamp =
      event["timestamp"]
      |> parse_timestamp(received_at)
      |> clamp_future(received_at)
      |> to_usec()

    %{
      event_id: normalize_event_id(event["event_id"]),
      timestamp: timestamp,
      received_at: received_at,
      level: normalize_level(event["level"]),
      message: extract_message(event),
      exception_type: str(exception["type"]),
      exception_value: str(exception["value"]),
      culprit: culprit(event, exception),
      release: str(event["release"]),
      environment: str(event["environment"], "production"),
      platform: str(event["platform"], "other"),
      sdk_name: str(get_in(event, ["sdk", "name"])),
      sdk_version: str(get_in(event, ["sdk", "version"])),
      user_id: str(get_in(event, ["user", "id"])),
      user_email: str(get_in(event, ["user", "email"])),
      user_ip: str(get_in(event, ["user", "ip_address"])),
      tags: event["tags"] |> normalize_tags() |> promote_server_name(event),
      trace_id: str(get_in(event, ["contexts", "trace", "trace_id"])),
      fingerprint_hash: Fingerprint.compute(event),
      grouping_version: Fingerprint.grouping_version(),
      title: title(event, exception),
      payload: Jason.encode!(event)
    }
  end

  # Последнее значение в exception values — то, что реально поймали
  # (конвенция протокола: цепочка от причины к следствию); форма может
  # быть и {"values": [...]}, и голым списком — см. Fingerprint.exception_values/1
  defp primary_exception(event) do
    case Fingerprint.exception_values(event) do
      [] -> %{}
      values -> values |> List.last() |> then(&if(is_map(&1), do: &1, else: %{}))
    end
  end

  defp normalize_event_id(id) when is_binary(id) and id != "" do
    normalized = id |> String.replace("-", "") |> String.downcase()

    if normalized =~ ~r/^[0-9a-f]{32}$/ do
      normalized
    else
      Envelope.generate_event_id()
    end
  end

  defp normalize_event_id(_), do: Envelope.generate_event_id()

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

  # Ecto `:utc_datetime_usec` требует precision 6, SDK шлют миллисекунды
  defp to_usec(%DateTime{microsecond: {us, _precision}} = dt) do
    %{dt | microsecond: {us, 6}}
  end

  @levels ~w(fatal error warning info debug)

  defp normalize_level(level) when is_binary(level) do
    level = String.downcase(level)
    if level in @levels, do: level, else: "error"
  end

  defp normalize_level(_), do: "error"

  # Для отображения предпочитаем итоговую строку (formatted); формы:
  # logentry-интерфейс, message-объект (sentry-elixir) и message-строка
  defp extract_message(event) do
    logentry = if is_map(event["logentry"]), do: event["logentry"], else: %{}
    message = event["message"]

    [
      logentry["formatted"],
      logentry["message"],
      is_map(message) && message["formatted"],
      is_map(message) && message["message"],
      message
    ]
    |> Enum.find(&(is_binary(&1) and &1 != ""))
    |> case do
      nil -> ""
      found -> truncate(found, 8192)
    end
  end

  defp title(event, exception) do
    cond do
      exception["type"] ->
        truncate("#{exception["type"]}: #{str(exception["value"])}", 500)

      (message = extract_message(event)) != "" ->
        truncate(message, 500)

      true ->
        "<unlabeled event>"
    end
  end

  defp culprit(event, exception) do
    top_in_app =
      exception
      |> Fingerprint.grouping_frames()
      # верхний кадр стека — последний в списке (конвенция протокола)
      |> List.last()

    cond do
      is_map(top_in_app) ->
        truncate(
          "#{Fingerprint.frame_module(top_in_app)} in #{Fingerprint.frame_function(top_in_app)}",
          500
        )

      is_binary(event["transaction"]) and event["transaction"] != "" ->
        truncate(event["transaction"], 500)

      true ->
        ""
    end
  end

  # tags приходят и картой, и списком пар — нормализуем в Map(String, String)
  defp normalize_tags(tags) when is_map(tags) do
    Map.new(tags, fn {k, v} -> {to_string(k), tag_value(v)} end)
  end

  defp normalize_tags(tags) when is_list(tags) do
    tags
    |> Enum.filter(&match?([_, _], &1))
    |> Map.new(fn [k, v] -> {to_string(k), tag_value(v)} end)
  end

  defp normalize_tags(_), do: %{}

  # server_name — top-level атрибут протокола (хост, где случилась ошибка);
  # продвигаем в теги, как это делает Sentry: виден в UI, истории и алертах.
  # Явно заданный SDK-тег с тем же ключом имеет приоритет.
  defp promote_server_name(tags, event) do
    case str(event["server_name"]) do
      "" -> tags
      host -> Map.put_new(tags, "server_name", truncate(host, 200))
    end
  end

  defp tag_value(nil), do: ""
  defp tag_value(v) when is_binary(v), do: truncate(v, 200)
  defp tag_value(v), do: v |> to_string() |> truncate(200)

  defp str(value, default \\ "")
  defp str(nil, default), do: default
  defp str(value, _default) when is_binary(value), do: value
  defp str(value, _default) when is_number(value) or is_atom(value), do: to_string(value)
  defp str(_, default), do: default

  defp truncate(string, max) do
    if String.length(string) > max, do: String.slice(string, 0, max), else: string
  end
end
