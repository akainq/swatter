defmodule Swatter.Pipeline.SpanBuilderTest do
  use ExUnit.Case, async: true

  alias Swatter.Pipeline.SpanBuilder

  @received_at ~U[2026-07-03 12:00:00.000000Z]
  @project %{id: 7, organization_id: 3}
  @trace_id "4541246aa98542e4980c637cd76e4b1a"
  @segment_id "b0e6f15b45c36b12"

  defp tx(overrides \\ %{}) do
    Map.merge(
      %{
        "type" => "transaction",
        "transaction" => "GET /checkout",
        "start_timestamp" => 1_783_000_000.0,
        "timestamp" => 1_783_000_000.25,
        "environment" => "staging",
        "release" => "api@1.2.3",
        "platform" => "node",
        "server_name" => "web-01",
        "tags" => %{"region" => "eu"},
        "contexts" => %{
          "trace" => %{
            "trace_id" => @trace_id,
            "span_id" => @segment_id,
            "op" => "http.server",
            "status" => "ok"
          }
        },
        "spans" => [
          %{
            "span_id" => "aaaaaaaaaaaaaaaa",
            "parent_span_id" => @segment_id,
            "op" => "db.query",
            "description" => "SELECT 1",
            "start_timestamp" => 1_783_000_000.05,
            "timestamp" => 1_783_000_000.15
          },
          %{
            "span_id" => "bbbbbbbbbbbbbbbb",
            "op" => "template.render",
            "start_timestamp" => 1_783_000_000.15,
            "timestamp" => 1_783_000_000.2
          }
        ]
      },
      overrides
    )
  end

  test "корневой сегмент + дочерние спаны с денормализованными измерениями" do
    rows = SpanBuilder.build(tx(), @project, @received_at)
    assert length(rows) == 3

    [root] = Enum.filter(rows, &(&1.is_segment == 1))
    assert root.span_id == @segment_id
    assert root.segment_id == @segment_id
    assert root.trace_id == @trace_id
    assert root.transaction_name == "GET /checkout"
    assert root.op == "http.server"
    assert root.status == "ok"
    assert root.description == "GET /checkout"
    assert_in_delta root.duration_ms, 250.0, 0.001

    children = Enum.filter(rows, &(&1.is_segment == 0))
    assert length(children) == 2

    # каждая строка несёт всё для фильтров без JOIN
    for row <- rows do
      assert row.org_id == 3
      assert row.project_id == 7
      assert row.transaction_name == "GET /checkout"
      assert row.environment == "staging"
      assert row.release == "api@1.2.3"
      assert row.tags == %{"region" => "eu", "server_name" => "web-01"}
    end

    db = Enum.find(children, &(&1.op == "db.query"))
    assert db.description == "SELECT 1"
    assert db.parent_span_id == @segment_id
    assert_in_delta db.duration_ms, 100.0, 0.001

    # parent_span_id по умолчанию — корневой сегмент
    render = Enum.find(children, &(&1.op == "template.render"))
    assert render.parent_span_id == @segment_id
  end

  test "битый trace_id → транзакция дропается целиком" do
    assert SpanBuilder.build(
             tx(%{"contexts" => %{"trace" => %{"trace_id" => "xxx", "span_id" => @segment_id}}}),
             @project,
             @received_at
           ) == []

    assert SpanBuilder.build(%{"transaction" => "no trace context"}, @project, @received_at) ==
             []
  end

  test "span с битым span_id пропускается, остальные остаются" do
    broken =
      tx(%{
        "spans" => [
          %{"span_id" => "not-hex", "op" => "bad"},
          %{
            "span_id" => "cccccccccccccccc",
            "op" => "ok.op",
            "start_timestamp" => 1_783_000_000.0,
            "timestamp" => 1_783_000_000.1
          }
        ]
      })

    rows = SpanBuilder.build(broken, @project, @received_at)
    assert length(rows) == 2
    assert Enum.any?(rows, &(&1.op == "ok.op"))
  end

  test "spans отсутствует → только корневой сегмент; дефолты на месте" do
    rows =
      SpanBuilder.build(
        %{
          "contexts" => %{"trace" => %{"trace_id" => @trace_id, "span_id" => @segment_id}}
        },
        @project,
        @received_at
      )

    assert [root] = rows
    assert root.transaction_name == "<unnamed>"
    assert root.environment == "production"
    assert root.platform == "other"
    assert root.duration_ms == 0.0
    assert root.tags == %{}
  end

  test "ISO-таймстемпы принимаются; end раньше start даёт нулевую длительность" do
    rows =
      SpanBuilder.build(
        tx(%{
          "start_timestamp" => "2026-07-03T11:59:00Z",
          "timestamp" => "2026-07-03T11:58:00Z"
        }),
        @project,
        @received_at
      )

    [root] = Enum.filter(rows, &(&1.is_segment == 1))
    assert root.duration_ms == 0.0
    assert DateTime.compare(root.end_ts, root.start_ts) == :eq
  end

  test "id с дефисами/верхним регистром нормализуются" do
    dashed = "4541246A-A985-42E4-980C-637CD76E4B1A"

    rows =
      SpanBuilder.build(
        tx(%{"contexts" => %{"trace" => %{"trace_id" => dashed, "span_id" => @segment_id}}}),
        @project,
        @received_at
      )

    [root | _] = rows
    assert root.trace_id == @trace_id
  end
end
