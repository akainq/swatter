defmodule Swatter.Issues.Issue do
  use Ecto.Schema

  @statuses ~w(unresolved resolved ignored)

  schema "issues" do
    field :fingerprint_hash, :string
    field :grouping_version, :integer, default: 1
    field :title, :string, default: ""
    field :culprit, :string, default: ""
    field :level, :string, default: "error"
    field :status, :string, default: "unresolved"
    field :first_seen, :utc_datetime_usec
    field :last_seen, :utc_datetime_usec
    field :times_seen, :integer, default: 1

    # регрессия (ADR-0011): resolved-issue вернулся в релизе новее того,
    # где был закрыт
    field :regressed, :boolean, default: false

    # вид события текущего upsert для алертов (ADR-0013): "new" | "regression"
    # | "ongoing". Виртуальное, не хранится — пайплайн решает по нему, слать ли.
    field :event_kind, :string, virtual: true

    belongs_to :organization, Swatter.Projects.Organization
    belongs_to :project, Swatter.Projects.Project
    belongs_to :first_release, Swatter.Releases.Release
    belongs_to :resolved_in_release, Swatter.Releases.Release

    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses
end
