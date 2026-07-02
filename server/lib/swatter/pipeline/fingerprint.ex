defmodule Swatter.Pipeline.Fingerprint do
  @moduledoc """
  Fingerprint v1 (ADR-0006). Приоритет источников:

  1. явный `fingerprint` из события (`{{ default }}` разворачивается в
     дефолтные компоненты);
  2. цепочка исключений: тип + in-app фреймы `(module, function)` без
     номеров строк;
  3. шаблон сообщения (`logentry.message`), иначе нормализованный message;
  4. fallback: level + нормализованный message.

  Детерминированно; смена алгоритма — только с инкрементом
  `grouping_version` (перегруппировки задним числом нет).
  """

  @grouping_version 1

  def grouping_version, do: @grouping_version

  @spec compute(map()) :: String.t()
  def compute(event) when is_map(event) do
    event
    |> components()
    |> Enum.intersperse(<<0>>)
    |> then(&:crypto.hash(:sha256, [Integer.to_string(@grouping_version), <<0>> | &1]))
    |> Base.encode16(case: :lower)
  end

  defp components(event) do
    case event["fingerprint"] do
      parts when is_list(parts) and parts != [] ->
        expanded =
          Enum.flat_map(parts, fn
            "{{ default }}" -> default_components(event)
            part -> [to_string(part)]
          end)

        if expanded == [], do: default_components(event), else: expanded

      _ ->
        default_components(event)
    end
  end

  defp default_components(event) do
    exception_components(event) || message_components(event) || fallback_components(event)
  end

  defp exception_components(event) do
    case exception_values(event) do
      [] -> nil
      values -> Enum.flat_map(values, &exception_value_components/1)
    end
  end

  @doc """
  Список exception values. Протокол допускает обе формы:
  `{"values": [...]}` и голый список (так шлёт, например, sentry-go).
  """
  def exception_values(event) when is_map(event) do
    case event["exception"] do
      %{"values" => values} when is_list(values) -> values
      values when is_list(values) -> values
      _ -> []
    end
  end

  defp exception_value_components(value) when is_map(value) do
    type = to_string(value["type"] || "Error")

    case grouping_frames(value) do
      [] ->
        # без стектрейса группируем по типу + нормализованному значению
        [type, normalize_message(to_string(value["value"] || ""))]

      frames ->
        [type | Enum.flat_map(frames, fn f -> [frame_module(f), frame_function(f)] end)]
    end
  end

  defp exception_value_components(_), do: []

  @doc "Фреймы, участвующие в группировке: in-app, а без них — все."
  def grouping_frames(exception_value) do
    frames = get_in(exception_value, ["stacktrace", "frames"]) || []
    frames = Enum.filter(frames, &is_map/1)

    case Enum.filter(frames, & &1["in_app"]) do
      [] -> frames
      in_app -> in_app
    end
  end

  @doc "Модуль фрейма: module, иначе basename файла."
  def frame_module(frame) do
    frame["module"] || basename(frame["filename"]) || basename(frame["abs_path"]) || "?"
  end

  @doc "Функция фрейма с нормализацией нестабильных частей."
  def frame_function(frame) do
    (frame["function"] || "?")
    |> String.replace(~r/0x[0-9a-fA-F]{4,}/, "0x")
    |> String.replace(~r/-fun-\d+-/, "-fun-")
    |> String.replace(~r/-anonymous-\d+-/, "-anonymous-")
  end

  defp basename(nil), do: nil
  defp basename(path) when is_binary(path), do: Path.basename(path)

  defp message_components(event) do
    case message_template(event) do
      nil -> nil
      message -> [normalize_message(message)]
    end
  end

  @doc """
  Шаблон сообщения для группировки. Протокол допускает `message` строкой
  и объектом `{"message": <шаблон>, "formatted": <итог>, "params": []}`
  (так шлёт, например, sentry-elixir); шаблон предпочтительнее —
  интерполяции не дробят группу.
  """
  def message_template(event) when is_map(event) do
    logentry = if is_map(event["logentry"]), do: event["logentry"], else: %{}
    message = event["message"]

    [
      logentry["message"],
      is_map(message) && message["message"],
      is_map(message) && message["formatted"],
      message
    ]
    |> Enum.find(&(is_binary(&1) and &1 != ""))
  end

  defp fallback_components(event) do
    [to_string(event["level"] || "error"), "<no message>"]
  end

  # вычищаем интерполированные значения, чтобы "id 123" и "id 456"
  # попадали в одну группу
  defp normalize_message(message) do
    message
    |> String.replace(
      ~r/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/,
      "<uuid>"
    )
    |> String.replace(~r/0x[0-9a-fA-F]+/, "<addr>")
    |> String.replace(~r/\b[0-9a-fA-F]{16,}\b/, "<hash>")
    |> String.replace(~r/\d+/, "<num>")
  end
end
