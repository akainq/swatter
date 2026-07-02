defmodule Swatter.Projects.Organization do
  use Ecto.Schema
  import Ecto.Changeset

  schema "organizations" do
    field :name, :string
    field :slug, :string

    has_many :projects, Swatter.Projects.Project

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(organization, attrs) do
    organization
    |> cast(attrs, [:name, :slug])
    |> validate_required([:name, :slug])
    |> validate_format(:slug, ~r/^[a-z0-9][a-z0-9-]*$/)
    |> validate_length(:slug, max: 64)
    |> unique_constraint(:slug)
  end
end
