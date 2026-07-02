defmodule Swatter.Repo.Migrations.AddRateLimitsToProjectKeys do
  use Ecto.Migration

  def change do
    alter table(:project_keys) do
      # NULL = дефолт из конфига :swatter, :ingest (ADR-0009)
      add :rate_limit_count, :integer
      add :rate_limit_window_seconds, :integer
    end
  end
end
