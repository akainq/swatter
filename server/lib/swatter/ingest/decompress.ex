defmodule Swatter.Ingest.Decompress do
  @moduledoc """
  Распаковка тела ingest-запроса (gzip/deflate) с жёстким потолком размера
  результата — защита от decompression-бомб: инфлейтим чанками через
  `:zlib.safeInflate/2` и прерываемся, как только превысили лимит.
  """

  @gzip_magic <<0x1F, 0x8B>>

  @doc """
  Распаковывает `body`, если клиент прислал сжатое (по Content-Encoding или
  по magic-байтам gzip). Несжатое тело возвращается как есть.
  """
  @spec maybe_decompress(binary(), [String.t()], pos_integer()) ::
          {:ok, binary()} | {:error, :payload_too_large | :invalid_compression}
  def maybe_decompress(body, content_encodings, max_bytes) do
    cond do
      Enum.any?(content_encodings, &(&1 =~ ~r/gzip|deflate/i)) -> inflate(body, max_bytes)
      match?(<<@gzip_magic, _::binary>>, body) -> inflate(body, max_bytes)
      true -> {:ok, body}
    end
  end

  defp inflate(body, max_bytes) do
    z = :zlib.open()

    try do
      # windowBits 15+32: автоопределение gzip- и zlib-обёрток
      :ok = :zlib.inflateInit(z, 47)
      inflate_loop(z, :zlib.safeInflate(z, body), [], 0, max_bytes)
    catch
      :error, _ -> {:error, :invalid_compression}
    after
      :zlib.close(z)
    end
  end

  defp inflate_loop(z, result, acc, size, max_bytes) do
    {status, chunk} = result
    size = size + IO.iodata_length(chunk)

    cond do
      size > max_bytes ->
        {:error, :payload_too_large}

      status == :finished ->
        {:ok, IO.iodata_to_binary([acc | chunk])}

      true ->
        inflate_loop(z, :zlib.safeInflate(z, []), [acc | chunk], size, max_bytes)
    end
  end
end
