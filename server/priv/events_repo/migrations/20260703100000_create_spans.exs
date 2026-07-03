defmodule Swatter.EventsRepo.Migrations.CreateSpans do
  use Ecto.Migration

  # Спаны трейсинга (ADR-0014): одна таблица, транзакция = корневой span
  # (is_segment=1), имя транзакции денормализовано в каждую строку.
  # ORDER BY — под оконные агрегаты; точечные выборки waterfall по trace_id
  # ускоряет bloom-filter skip-index.
  def change do
    create table(:spans,
             primary_key: false,
             engine: "MergeTree",
             options: [
               partition_by: "toYYYYMM(start_ts)",
               order_by: "(project_id, start_ts)",
               # 30 дней: спаны на порядок объёмнее ошибок (ADR-0014; пересмотр в ADR-0010)
               ttl: "toDateTime(start_ts) + INTERVAL 30 DAY"
             ]
           ) do
      add :org_id, :UInt64
      add :project_id, :UInt64
      add :trace_id, :"FixedString(32)"
      add :span_id, :"FixedString(16)"
      add :parent_span_id, :string
      # span_id корневого спана транзакции — общий для всех строк сегмента
      add :segment_id, :"FixedString(16)"
      add :is_segment, :UInt8
      # не `transaction` — бережём SQL-парсер от ключевого слова
      add :transaction_name, :string
      add :op, :"LowCardinality(String)"
      add :description, :string
      add :status, :"LowCardinality(String)"
      add :start_ts, :"DateTime64(3, 'UTC')"
      add :end_ts, :"DateTime64(3, 'UTC')"
      add :duration_ms, :Float64
      add :environment, :"LowCardinality(String)"
      add :release, :string
      add :platform, :"LowCardinality(String)"
      add :tags, :"Map(String, String)"
      add :received_at, :"DateTime64(3, 'UTC')"
    end

    execute(
      "ALTER TABLE spans ADD INDEX idx_spans_trace trace_id TYPE bloom_filter GRANULARITY 4",
      "ALTER TABLE spans DROP INDEX idx_spans_trace"
    )
  end
end
