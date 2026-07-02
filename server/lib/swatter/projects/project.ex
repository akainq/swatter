defmodule Swatter.Projects.Project do
  use Ecto.Schema
  import Ecto.Changeset

  schema "projects" do
    field :name, :string
    field :slug, :string
    field :platform, :string

    belongs_to :organization, Swatter.Projects.Organization
    has_many :keys, Swatter.Projects.ProjectKey

    timestamps(type: :utc_datetime_usec)
  end

  # зарезервированы под статические сегменты роутов SPA
  @reserved_slugs ~w(projects new settings issues)

  def changeset(project, attrs) do
    project
    |> cast(attrs, [:name, :slug, :platform])
    |> validate_required([:name, :slug])
    |> validate_format(:slug, ~r/^[a-z0-9][a-z0-9-]*$/)
    |> validate_length(:slug, max: 64)
    |> validate_exclusion(:slug, @reserved_slugs, message: "is reserved")
    |> unique_constraint([:organization_id, :slug])
  end

  @doc "Правка из dashboard: slug неизменяем (в нём живут ссылки и роуты)."
  def update_changeset(project, attrs) do
    project
    |> cast(attrs, [:name, :platform])
    |> validate_required([:name])
    |> validate_length(:name, max: 200)
  end
end
