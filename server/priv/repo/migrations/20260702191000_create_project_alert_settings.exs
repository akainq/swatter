defmodule Swatter.Repo.Migrations.CreateProjectAlertSettings do
  use Ecto.Migration

  # Per-project настройки алертов (ADR-0013): куда слать и какие правила
  # включены. Одна строка на проект; отсутствие строки трактуется как дефолты.
  def change do
    create table(:project_alert_settings) do
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :enabled, :boolean, null: false, default: true
      add :telegram_chat_id, :string
      add :on_new_issue, :boolean, null: false, default: true
      add :on_regression, :boolean, null: false, default: true
      add :frequency_threshold, :integer
      add :frequency_window_seconds, :integer, null: false, default: 300
      add :ai_enabled, :boolean, null: false, default: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:project_alert_settings, [:project_id])
  end
end
