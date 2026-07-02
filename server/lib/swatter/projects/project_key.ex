defmodule Swatter.Projects.ProjectKey do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "project_keys" do
    field :public_key, :string
    field :active, :boolean, default: true
    # NULL = дефолт из конфига :swatter, :ingest (ADR-0009)
    field :rate_limit_count, :integer
    field :rate_limit_window_seconds, :integer

    belongs_to :project, Swatter.Projects.Project

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(key, attrs) do
    key
    |> cast(attrs, [:active, :rate_limit_count, :rate_limit_window_seconds])
    |> validate_number(:rate_limit_count, greater_than: 0)
    |> validate_number(:rate_limit_window_seconds, greater_than: 0)
    |> put_public_key()
  end

  defp put_public_key(changeset) do
    case get_field(changeset, :public_key) do
      nil -> put_change(changeset, :public_key, generate_public_key())
      _ -> changeset
    end
  end

  # 32 hex chars, как у публичного ключа Sentry DSN
  def generate_public_key do
    16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
  end

  @doc "DSN для этого ключа: {scheme}://{public_key}@{host}[:port]/{project_id}"
  def dsn(%__MODULE__{} = key, base_url) do
    uri = URI.parse(base_url)
    port = if uri.port in [80, 443], do: "", else: ":#{uri.port}"
    "#{uri.scheme}://#{key.public_key}@#{uri.host}#{port}/#{key.project_id}"
  end
end
