defmodule Swatter.Conformance.TracingTest do
  @moduledoc """
  Tracing-conformance (M4, ADR-0014): официальный @sentry/node с
  `tracesSampleRate: 1` шлёт транзакцию со спанами; Swatter раскладывает её
  в строки таблицы `spans` (корневой сегмент + дочерние).
  """

  use Swatter.DataCase, async: false

  @moduletag :conformance
  @moduletag timeout: 300_000

  import Ecto.Query, only: [from: 2]
  import Swatter.ConformanceHelpers

  alias Swatter.EventsRepo
  alias Swatter.Spans.Span

  @dir Path.expand("../../../conformance/node", __DIR__)
  @node System.find_executable("node")

  if @node do
    test "@sentry/node с tracesSampleRate=1 доставляет транзакцию до spans" do
      {project, dsn} = prepare!()
      start_supervised!({Swatter.Pipeline, name: __MODULE__.Pipeline})

      bun = System.find_executable("bun") || "bun"
      run!(bun, ["install"], cd: @dir)

      out = run!(@node, ["send_transaction.js"], cd: @dir, env: [{"SWATTER_DSN", dsn}])
      assert out =~ "transaction sent"

      rows = await_spans!(project.id)

      [root] = Enum.filter(rows, &(&1.is_segment == 1))
      assert root.transaction_name == "conformance-transaction"
      assert root.op == "test.run"
      assert root.environment == "conformance"
      assert root.release == "conformance@0.0.1"

      # спал минимум 40 мс внутри — длительность корня не может быть меньше
      assert root.duration_ms >= 30

      children = Enum.filter(rows, &(&1.is_segment == 0))
      assert length(children) >= 2
      assert Enum.any?(children, &(&1.op == "db.query"))

      # все спаны принадлежат одному трейсу и сегменту корня
      assert Enum.all?(rows, &(&1.trace_id == root.trace_id))
      assert Enum.all?(rows, &(&1.segment_id == root.span_id))
    end
  else
    @tag :skip
    test "tracing conformance: нужен node" do
      flunk("unreachable")
    end
  end

  defp await_spans!(project_id, attempts \\ 60) do
    rows = EventsRepo.all(from s in Span, where: s.project_id == ^project_id)

    cond do
      Enum.any?(rows, &(&1.is_segment == 1)) ->
        rows

      attempts > 0 ->
        Process.sleep(250)
        await_spans!(project_id, attempts - 1)

      true ->
        flunk("спаны не появились (строк: #{length(rows)})")
    end
  end
end
