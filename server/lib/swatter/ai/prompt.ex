defmodule Swatter.AI.Prompt do
  @moduledoc """
  Сборка промпта для анализа issue (ADR-0016): метаданные issue + контекст
  последнего события из ClickHouse (символикованный in-app стек, breadcrumbs,
  теги). Всё best-effort: события может не быть — анализируем по issue.
  """

  alias Swatter.Issues.Issue

  # потолок пользовательской части промпта — держим расход токенов в узде
  @max_user_chars 8_000
  @max_frames 12
  @max_breadcrumbs 10

  @system """
  Ты — опытный инженер, разбирающий ошибки из системы мониторинга (аналог Sentry).
  По данным ошибки определи её суть и вероятную причину и предложи направление исправления.
  Отвечай СТРОГО одним JSON-объектом без пояснений и markdown-обёрток, с ключами:
  "summary" — суть проблемы, 1-2 предложения по-русски;
  "probable_cause" — вероятная причина, по-русски;
  "severity" — одно из "low", "medium", "high", "critical";
  "suggested_fix" — конкретное направление фикса, по-русски.
  """

  @spec build(Issue.t(), map() | nil) :: [map()]
  def build(%Issue{} = issue, event) do
    [
      %{role: "system", content: @system},
      %{role: "user", content: user_content(issue, event)}
    ]
  end

  defp user_content(issue, event) do
    payload = decode_payload(event)

    [
      "Issue: #{issue.title}",
      line("Culprit: ", issue.culprit),
      "Level: #{issue.level} · встречена #{issue.times_seen} раз",
      event && "Environment: #{event.environment} · Release: #{event.release}",
      event && line("Platform: ", event.platform),
      event && tags_line(event.tags),
      line("Message: ", event && event.message),
      frames_block(payload),
      breadcrumbs_block(payload)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
    |> truncate(@max_user_chars)
  end

  defp decode_payload(nil), do: %{}

  defp decode_payload(%{payload: payload}) when is_binary(payload) do
    case Jason.decode(payload) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp decode_payload(_), do: %{}

  defp line(_prefix, value) when value in [nil, ""], do: nil
  defp line(prefix, value), do: prefix <> to_string(value)

  defp tags_line(tags) when is_map(tags) and map_size(tags) > 0 do
    "Tags: " <> Enum.map_join(tags, " · ", fn {k, v} -> "#{k}=#{v}" end)
  end

  defp tags_line(_), do: nil

  # стек последнего exception: in-app кадры (или все, если in-app нет),
  # верхний кадр первым — конвенция протокола хранит его последним
  defp frames_block(payload) do
    frames =
      payload
      |> exception_frames()
      |> prefer_in_app()
      |> Enum.take(-@max_frames)
      |> Enum.reverse()

    case frames do
      [] ->
        nil

      frames ->
        "Стек (верхний кадр первым):\n" <>
          Enum.map_join(frames, "\n", &format_frame/1)
    end
  end

  defp exception_frames(payload) do
    values =
      case payload["exception"] do
        %{"values" => values} when is_list(values) -> values
        values when is_list(values) -> values
        _ -> []
      end

    case List.last(values) do
      %{"stacktrace" => %{"frames" => frames}} when is_list(frames) -> frames
      _ -> []
    end
  end

  defp prefer_in_app(frames) do
    case Enum.filter(frames, &(is_map(&1) and &1["in_app"] == true)) do
      [] -> Enum.filter(frames, &is_map/1)
      in_app -> in_app
    end
  end

  defp format_frame(frame) do
    location = "#{frame["filename"] || frame["abs_path"] || "?"}:#{frame["lineno"] || "?"}"
    function = frame["function"] || "?"

    case frame["context_line"] do
      context when is_binary(context) and context != "" ->
        "  #{location} #{function} — #{String.trim(context)}"

      _ ->
        "  #{location} #{function}"
    end
  end

  defp breadcrumbs_block(payload) do
    crumbs =
      case payload["breadcrumbs"] do
        %{"values" => values} when is_list(values) -> values
        values when is_list(values) -> values
        _ -> []
      end

    case Enum.take(crumbs, -@max_breadcrumbs) do
      [] ->
        nil

      crumbs ->
        "Breadcrumbs (последние):\n" <>
          Enum.map_join(crumbs, "\n", fn crumb ->
            "  [#{crumb["category"] || crumb["type"] || "?"}] #{crumb["message"] || ""}"
          end)
    end
  end

  defp truncate(string, max) do
    if String.length(string) > max, do: String.slice(string, 0, max), else: string
  end
end
