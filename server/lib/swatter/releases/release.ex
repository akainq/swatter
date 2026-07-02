defmodule Swatter.Releases.Release do
  use Ecto.Schema

  schema "releases" do
    field :version, :string
    field :ordinal, :integer
    field :first_event_at, :utc_datetime_usec

    belongs_to :project, Swatter.Projects.Project

    timestamps(type: :utc_datetime_usec)
  end
end
