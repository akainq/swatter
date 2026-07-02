defmodule Swatter.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :email, :string
    field :name, :string, default: ""
    field :password, :string, virtual: true, redact: true
    field :password_hash, :string, redact: true

    has_many :memberships, Swatter.Accounts.Membership

    timestamps(type: :utc_datetime_usec)
  end

  def registration_changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :name, :password])
    |> validate_required([:email, :password])
    |> update_change(:email, &(&1 |> String.trim() |> String.downcase()))
    |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+\.[^@,;\s]+$/,
      message: "must be a valid email"
    )
    |> validate_length(:email, max: 160)
    |> validate_length(:password, min: 8, max: 72)
    |> unique_constraint(:email)
    |> hash_password()
  end

  defp hash_password(changeset) do
    case get_change(changeset, :password) do
      password when is_binary(password) ->
        if changeset.valid? do
          changeset
          |> put_change(:password_hash, Pbkdf2.hash_pwd_salt(password))
          |> delete_change(:password)
        else
          changeset
        end

      _ ->
        changeset
    end
  end

  @doc "Проверка пароля с защитой от timing-атак при отсутствии пользователя."
  def valid_password?(%__MODULE__{password_hash: hash}, password)
      when is_binary(hash) and is_binary(password) do
    Pbkdf2.verify_pass(password, hash)
  end

  def valid_password?(_, _) do
    Pbkdf2.no_user_verify()
    false
  end
end
