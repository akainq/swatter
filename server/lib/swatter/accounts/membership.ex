defmodule Swatter.Accounts.Membership do
  use Ecto.Schema
  import Ecto.Changeset

  @roles ~w(owner admin member)

  schema "memberships" do
    field :role, :string, default: "member"

    belongs_to :user, Swatter.Accounts.User
    belongs_to :organization, Swatter.Projects.Organization

    timestamps(type: :utc_datetime_usec)
  end

  def roles, do: @roles

  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [:role])
    |> validate_inclusion(:role, @roles)
    |> unique_constraint([:user_id, :organization_id])
  end
end
