defmodule Swatter.Symbolication.SourceMapTest do
  use ExUnit.Case, async: true

  alias Swatter.Symbolication.SourceMap

  test "разбирает минимальную карту и мапит generated → source" do
    json =
      Jason.encode!(%{
        "version" => 3,
        "sources" => ["src/a.ts"],
        "names" => [],
        # ";AACA": строка 0 пустая; строка 1: сегмент [0,0,1,0]
        "mappings" => ";AACA"
      })

    {:ok, sm} = SourceMap.parse(json)

    # generated (line 2, col 1) → source a.ts, строка 2 (src_line 1 + 1)
    result = SourceMap.lookup(sm, 2, 1)
    assert result.source == "src/a.ts"
    assert result.line == 2
    assert result.column == 1
  end

  test "мапит с именем и отдаёт исходный контекст" do
    json =
      Jason.encode!(%{
        "version" => 3,
        "sources" => ["src/app.ts"],
        "names" => ["handleClick"],
        "sourcesContent" => ["line0\nline1\nfunction handleClick() {}\nline3"],
        # сегмент [0,0,2,0,0]: gen col 0 → source 0, src line 2, col 0, name 0
        "mappings" => "AAEAA"
      })

    {:ok, sm} = SourceMap.parse(json)
    result = SourceMap.lookup(sm, 1, 1)

    assert result.source == "src/app.ts"
    assert result.line == 3
    assert result.name == "handleClick"
    assert result.context["line"] == "function handleClick() {}"
    assert "line1" in result.context["pre"]
  end

  test "выбирает сегмент с наибольшим gen_col <= target" do
    # строка 0: два сегмента — col 0 → src line 0; col 5 → src line 1
    # "AAAA,KACA": AAAA=[0,0,0,0]; KACA=[5,0,1,0] (K=5)
    json =
      Jason.encode!(%{
        "version" => 3,
        "sources" => ["a.ts"],
        "mappings" => "AAAA,KACA"
      })

    {:ok, sm} = SourceMap.parse(json)

    assert SourceMap.lookup(sm, 1, 1).line == 1
    # col 6 (>= 5) → второй сегмент, src line 2
    assert SourceMap.lookup(sm, 1, 6).line == 2
  end

  test "nil для строки без маппинга и для не-v3" do
    {:ok, sm} = SourceMap.parse(Jason.encode!(%{"version" => 3, "mappings" => "AAAA"}))
    assert SourceMap.lookup(sm, 99, 1) == nil

    assert SourceMap.parse(Jason.encode!(%{"version" => 2, "mappings" => ""})) == :error
    assert SourceMap.parse("not json") == :error
  end
end
