defmodule Swatter.Repo.Migrations.CreateOrgsProjectsKeys do
  use Ecto.Migration

  def change do
    create table(:organizations) do
      add :name, :string, null: false
      add :slug, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:organizations, [:slug])

    create table(:projects) do
      add :organization_id, references(:organizations, on_delete: :restrict), null: false
      add :name, :string, null: false
      add :slug, :string, null: false
      add :platform, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:projects, [:organization_id, :slug])

    create table(:project_keys) do
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :public_key, :string, null: false
      add :active, :boolean, null: false, default: true

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:project_keys, [:public_key])
    create index(:project_keys, [:project_id])
  end
end
