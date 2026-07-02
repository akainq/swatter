defmodule Swatter.EventsRepo.Migrations.CreateEvents do
  use Ecto.Migration

  def change do
    create table(:events,
             primary_key: false,
             engine: "MergeTree",
             options: [
               partition_by: "toYYYYMM(timestamp)",
               order_by: "(project_id, issue_id, timestamp)",
               # 90 дней по умолчанию до ADR-0010 (retention per-project)
               ttl: "toDateTime(timestamp) + INTERVAL 90 DAY"
             ]
           ) do
      add :org_id, :UInt64
      add :project_id, :UInt64
      add :issue_id, :UInt64
      add :event_id, :"FixedString(32)"
      # именно с 'UTC': tz-типы у Ch-адаптера принимают DateTime (usec),
      # без tz — только NaiveDateTime
      add :timestamp, :"DateTime64(3, 'UTC')"
      add :received_at, :"DateTime64(3, 'UTC')"
      add :level, :"LowCardinality(String)"
      add :message, :string
      add :exception_type, :string
      add :exception_value, :string
      add :culprit, :string
      add :release, :string
      add :environment, :"LowCardinality(String)"
      add :platform, :"LowCardinality(String)"
      add :sdk_name, :"LowCardinality(String)"
      add :sdk_version, :string
      add :user_id, :string
      add :user_email, :string
      add :user_ip, :string
      add :tags, :"Map(String, String)"
      add :trace_id, :string
      # полный нормализованный event JSON — источник для деталки issue
      add :payload, :string
    end
  end
end
