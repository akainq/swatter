defmodule Swatter.Spans.Span do
  @moduledoc """
  Строка таблицы `spans` в ClickHouse (ADR-0014). Транзакция — корневой
  span (`is_segment = 1`); имя транзакции денормализовано в каждую строку.
  Схема нужна для типизированной RowBinary-кодировки в `insert_all` и чтений.
  """

  use Ecto.Schema

  @primary_key false
  schema "spans" do
    field :org_id, Ch, type: "UInt64"
    field :project_id, Ch, type: "UInt64"
    field :trace_id, Ch, type: "FixedString(32)"
    field :span_id, Ch, type: "FixedString(16)"
    field :parent_span_id, Ch, type: "String"
    field :segment_id, Ch, type: "FixedString(16)"
    field :is_segment, Ch, type: "UInt8"
    field :transaction_name, Ch, type: "String"
    field :op, Ch, type: "LowCardinality(String)"
    field :description, Ch, type: "String"
    field :status, Ch, type: "LowCardinality(String)"
    field :start_ts, Ch, type: "DateTime64(3, 'UTC')"
    field :end_ts, Ch, type: "DateTime64(3, 'UTC')"
    field :duration_ms, Ch, type: "Float64"
    field :environment, Ch, type: "LowCardinality(String)"
    field :release, Ch, type: "String"
    field :platform, Ch, type: "LowCardinality(String)"
    field :tags, Ch, type: "Map(String, String)"
    field :received_at, Ch, type: "DateTime64(3, 'UTC')"
  end
end
