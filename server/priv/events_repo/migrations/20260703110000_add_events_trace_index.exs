defmodule Swatter.EventsRepo.Migrations.AddEventsTraceIndex do
  use Ecto.Migration

  # error↔trace (ADR-0014): точечные выборки ошибок по trace_id поперёк
  # проектов организации — bloom-filter skip-index, как у spans
  def change do
    execute(
      "ALTER TABLE events ADD INDEX idx_events_trace trace_id TYPE bloom_filter GRANULARITY 4",
      "ALTER TABLE events DROP INDEX idx_events_trace"
    )
  end
end
