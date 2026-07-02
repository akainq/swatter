defmodule Swatter.Events.Event do
  @moduledoc """
  Строка таблицы `events` в ClickHouse. Схема нужна для типизированной
  RowBinary-кодировки в `EventsRepo.insert_all/2` и для чтений.
  """

  use Ecto.Schema

  @primary_key false
  schema "events" do
    field :org_id, Ch, type: "UInt64"
    field :project_id, Ch, type: "UInt64"
    field :issue_id, Ch, type: "UInt64"
    field :event_id, Ch, type: "FixedString(32)"
    field :timestamp, Ch, type: "DateTime64(3, 'UTC')"
    field :received_at, Ch, type: "DateTime64(3, 'UTC')"
    field :level, Ch, type: "LowCardinality(String)"
    field :message, Ch, type: "String"
    field :exception_type, Ch, type: "String"
    field :exception_value, Ch, type: "String"
    field :culprit, Ch, type: "String"
    field :release, Ch, type: "String"
    field :environment, Ch, type: "LowCardinality(String)"
    field :platform, Ch, type: "LowCardinality(String)"
    field :sdk_name, Ch, type: "LowCardinality(String)"
    field :sdk_version, Ch, type: "String"
    field :user_id, Ch, type: "String"
    field :user_email, Ch, type: "String"
    field :user_ip, Ch, type: "String"
    field :tags, Ch, type: "Map(String, String)"
    field :trace_id, Ch, type: "String"
    field :payload, Ch, type: "String"
  end
end
