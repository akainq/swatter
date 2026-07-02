defmodule Swatter.Ingest.Envelope do
  @moduledoc """
  Разбор Sentry envelope (ADR-0001).

  На приёме используется только `parse_header/1` (инвариант: никакой
  тяжёлой работы в запросе); полный `parse/1` c items — в пайплайне.

  Формат: первая строка — JSON-заголовок envelope; далее для каждого item —
  строка JSON-заголовка (`type`, опционально `length`) и payload: либо ровно
  `length` байт, либо (без `length`) до конца строки.
  """

  @spec parse_header(binary()) :: {:ok, map()} | {:error, :invalid_envelope}
  def parse_header(binary) when is_binary(binary) do
    {line, _rest} = split_line(binary)

    case Jason.decode(line) do
      {:ok, header} when is_map(header) -> {:ok, header}
      _ -> {:error, :invalid_envelope}
    end
  end

  @doc "Полный разбор: заголовок + список items `{item_header, payload}`."
  @spec parse(binary()) :: {:ok, map(), [{map(), binary()}]} | {:error, :invalid_envelope}
  def parse(binary) when is_binary(binary) do
    {line, rest} = split_line(binary)

    with {:ok, header} when is_map(header) <- Jason.decode(line),
         {:ok, items} <- parse_items(rest, []) do
      {:ok, header, items}
    else
      _ -> {:error, :invalid_envelope}
    end
  end

  defp parse_items("", acc), do: {:ok, Enum.reverse(acc)}

  defp parse_items(binary, acc) do
    {line, rest} = split_line(binary)

    if line == "" do
      # финальный перевод строки / пустая строка между items
      parse_items(rest, acc)
    else
      case Jason.decode(line) do
        {:ok, %{"length" => len} = item_header} when is_integer(len) and len >= 0 ->
          case rest do
            <<payload::binary-size(^len), rest2::binary>> ->
              parse_items(strip_newline(rest2), [{item_header, payload} | acc])

            _ ->
              {:error, :invalid_envelope}
          end

        {:ok, item_header} when is_map(item_header) ->
          # payload без length — до конца строки
          {payload, rest2} = split_line(rest)
          parse_items(rest2, [{item_header, payload} | acc])

        _ ->
          {:error, :invalid_envelope}
      end
    end
  end

  defp split_line(binary) do
    case :binary.split(binary, "\n") do
      [line, rest] -> {String.trim_trailing(line, "\r"), rest}
      [line] -> {String.trim_trailing(line, "\r"), ""}
    end
  end

  defp strip_newline("\n" <> rest), do: rest
  defp strip_newline("\r\n" <> rest), do: rest
  defp strip_newline(rest), do: rest

  @doc "event_id из заголовка envelope либо свежесгенерированный (32 hex)."
  @spec event_id(map()) :: String.t()
  def event_id(header) do
    case header do
      %{"event_id" => id} when is_binary(id) and id != "" -> normalize_event_id(id)
      _ -> generate_event_id()
    end
  end

  def generate_event_id do
    Ecto.UUID.generate() |> String.replace("-", "")
  end

  # SDK могут прислать UUID с дефисами; формат ответа Sentry — 32 hex без них
  defp normalize_event_id(id), do: id |> String.replace("-", "") |> String.downcase()
end
