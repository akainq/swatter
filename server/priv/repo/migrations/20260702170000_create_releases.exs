defmodule Swatter.Repo.Migrations.CreateReleases do
  use Ecto.Migration

  def change do
    create table(:releases) do
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :version, :string, null: false

      # монотонный порядковый в рамках проекта: сравнение «новее/старее»
      # без разбора семантики версий (ADR-0011: regression по порядку)
      add :ordinal, :bigint, null: false
      add :first_event_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:releases, [:project_id, :version])
    create unique_index(:releases, [:project_id, :ordinal])

    alter table(:issues) do
      add :first_release_id, references(:releases, on_delete: :nilify_all)
      add :resolved_in_release_id, references(:releases, on_delete: :nilify_all)

      # true, если resolved-issue вернулся в релизе новее того, где закрыли
      add :regressed, :boolean, null: false, default: false
    end
  end
end
