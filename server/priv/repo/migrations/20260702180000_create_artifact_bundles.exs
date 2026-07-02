defmodule Swatter.Repo.Migrations.CreateArtifactBundles do
  use Ecto.Migration

  def change do
    create table(:artifact_bundles) do
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :debug_id, :string, null: false
      # source_map | minified_source (ADR-0012)
      add :type, :string, null: false
      add :name, :string

      # контент хранится gzip-сжатым bytea в этой же строке (ADR-0012)
      add :content, :binary, null: false
      add :content_size, :bigint, null: false
      add :compressed_size, :bigint, null: false

      timestamps(type: :utc_datetime_usec)
    end

    # идемпотентность: повторная загрузка того же (project, debug_id, type)
    # заменяет содержимое
    create unique_index(:artifact_bundles, [:project_id, :debug_id, :type])
  end
end
