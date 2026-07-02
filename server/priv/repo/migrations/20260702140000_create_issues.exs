defmodule Swatter.Repo.Migrations.CreateIssues do
  use Ecto.Migration

  def change do
    create table(:issues) do
      add :organization_id, references(:organizations, on_delete: :restrict), null: false
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :fingerprint_hash, :string, size: 64, null: false
      add :grouping_version, :integer, null: false, default: 1
      add :title, :text, null: false, default: ""
      add :culprit, :text, null: false, default: ""
      add :level, :string, null: false, default: "error"
      add :status, :string, null: false, default: "unresolved"
      add :first_seen, :utc_datetime_usec, null: false
      add :last_seen, :utc_datetime_usec, null: false
      add :times_seen, :bigint, null: false, default: 1

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:issues, [:project_id, :fingerprint_hash])
    create index(:issues, [:project_id, :last_seen])
    create index(:issues, [:project_id, :status])
  end
end
