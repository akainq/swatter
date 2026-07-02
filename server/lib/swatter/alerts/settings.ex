defmodule Swatter.Alerts.Settings do
  @moduledoc """
  Per-project настройки алертов (ADR-0013): куда слать (Telegram `chat_id`) и
  какие правила включены. Одна строка на проект; отсутствие строки означает
  дефолты (`%Settings{}`), чтобы не требовать записи при создании проекта.
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "project_alert_settings" do
    field :enabled, :boolean, default: true
    field :telegram_chat_id, :string
    field :on_new_issue, :boolean, default: true
    field :on_regression, :boolean, default: true
    field :frequency_threshold, :integer
    field :frequency_window_seconds, :integer, default: 300
    field :ai_enabled, :boolean, default: false

    belongs_to :project, Swatter.Projects.Project

    timestamps(type: :utc_datetime)
  end

  @fields ~w(enabled telegram_chat_id on_new_issue on_regression
             frequency_threshold frequency_window_seconds ai_enabled)a

  def changeset(settings, attrs) do
    settings
    |> cast(attrs, @fields)
    |> validate_number(:frequency_threshold, greater_than: 0)
    |> validate_number(:frequency_window_seconds, greater_than: 0)
    |> unique_constraint(:project_id)
  end
end
