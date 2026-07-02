defmodule Swatter.Artifacts.ArtifactBundle do
  use Ecto.Schema

  @types ~w(source_map minified_source)

  schema "artifact_bundles" do
    field :debug_id, :string
    field :type, :string
    field :name, :string
    field :content, :binary
    field :content_size, :integer
    field :compressed_size, :integer

    belongs_to :project, Swatter.Projects.Project

    timestamps(type: :utc_datetime_usec)
  end

  def types, do: @types
end
