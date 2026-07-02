defmodule Swatter.Repo.Migrations.CreateUsersAuth do
  use Ecto.Migration

  def change do
    create table(:users) do
      add :email, :string, null: false
      add :name, :string, null: false, default: ""
      add :password_hash, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:users, [:email])

    create table(:memberships) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :organization_id, references(:organizations, on_delete: :delete_all), null: false
      add :role, :string, null: false, default: "member"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:memberships, [:user_id, :organization_id])
    create index(:memberships, [:organization_id])

    create table(:user_tokens) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :token_hash, :binary, null: false
      add :context, :string, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:user_tokens, [:token_hash])
    create index(:user_tokens, [:user_id])
  end
end
