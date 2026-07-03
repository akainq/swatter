defmodule Swatter.Repo.Migrations.CreateIssueAiAnalyses do
  use Ecto.Migration

  # AI-анализ issue (ADR-0016): одна строка на issue, перезаписывается при
  # повторном запросе. Отдельная таблица — не раздуваем горячую issues.
  def change do
    create table(:issue_ai_analyses) do
      add :issue_id, references(:issues, on_delete: :delete_all), null: false
      add :status, :string, null: false, default: "pending"
      add :summary, :text
      add :probable_cause, :text
      add :severity, :string
      add :suggested_fix, :text
      add :model, :string
      add :error, :text
      add :analyzed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:issue_ai_analyses, [:issue_id])
  end
end
