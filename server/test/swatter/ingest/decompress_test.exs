defmodule Swatter.Ingest.DecompressTest do
  use ExUnit.Case, async: true

  alias Swatter.Ingest.Decompress

  @max 5_000_000

  test "распаковывает gzip по content-encoding" do
    payload = "hello envelope"
    assert {:ok, ^payload} = Decompress.maybe_decompress(:zlib.gzip(payload), ["gzip"], @max)
  end

  test "распаковывает zlib-deflate по content-encoding" do
    payload = "deflated body"

    assert {:ok, ^payload} =
             Decompress.maybe_decompress(:zlib.compress(payload), ["deflate"], @max)
  end

  test "узнаёт gzip по magic-байтам без заголовка" do
    payload = "sniffed"
    assert {:ok, ^payload} = Decompress.maybe_decompress(:zlib.gzip(payload), [], @max)
  end

  test "пропускает несжатое тело как есть" do
    assert {:ok, "plain"} = Decompress.maybe_decompress("plain", [], @max)
  end

  test "ошибка на битом gzip" do
    assert {:error, :invalid_compression} =
             Decompress.maybe_decompress(<<0x1F, 0x8B, 1, 2, 3>>, ["gzip"], @max)
  end

  test "обрывает decompression-бомбу на лимите" do
    bomb = :zlib.gzip(:binary.copy(<<0>>, @max + 1_000_000))

    # сжатая бомба маленькая, распакованная — за лимитом
    assert byte_size(bomb) < 100_000
    assert {:error, :payload_too_large} = Decompress.maybe_decompress(bomb, ["gzip"], @max)
  end
end
