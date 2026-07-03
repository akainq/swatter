defmodule Swatter.AI.Analysis do
  @moduledoc """
  Результат AI-анализа issue (ADR-0016). Одна строка на issue (upsert);
  `status`: `pending` (джоба поставлена) → `ok` | `error`.
  """

  use Ecto.Schema

  @severities ~w(low medium high critical)

  schema "issue_ai_analyses" do
    field :status, :string, default: "pending"
    field :summary, :string
    field :probable_cause, :string
    field :severity, :string
    field :suggested_fix, :string
    field :model, :string
    field :error, :string
    field :analyzed_at, :utc_datetime

    belongs_to :issue, Swatter.Issues.Issue

    timestamps(type: :utc_datetime)
  end

  def severities, do: @severities
end
