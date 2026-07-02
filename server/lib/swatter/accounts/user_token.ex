defmodule Swatter.Accounts.UserToken do
  @moduledoc """
  Сессионные токены (ADR-0007: cookie-сессии с ревокацией). В cookie —
  сырой токен, в БД — только SHA-256 от него: утечка БД не даёт сессий.
  """

  use Ecto.Schema

  import Ecto.Query

  @rand_size 32
  @session_validity_days 60

  schema "user_tokens" do
    field :token_hash, :binary
    field :context, :string

    belongs_to :user, Swatter.Accounts.User

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc "Возвращает {сырой токен для cookie, struct для вставки}."
  def build_session_token(user) do
    token = :crypto.strong_rand_bytes(@rand_size)

    {Base.url_encode64(token, padding: false),
     %__MODULE__{token_hash: hash(token), context: "session", user_id: user.id}}
  end

  def verify_session_token_query(encoded_token) do
    with {:ok, token} <- Base.url_decode64(encoded_token, padding: false) do
      query =
        from t in __MODULE__,
          where: t.token_hash == ^hash(token) and t.context == "session",
          where: t.inserted_at > ago(@session_validity_days, "day"),
          join: u in assoc(t, :user),
          select: u

      {:ok, query}
    end
  end

  def by_raw_token_query(encoded_token) do
    with {:ok, token} <- Base.url_decode64(encoded_token, padding: false) do
      {:ok, from(t in __MODULE__, where: t.token_hash == ^hash(token))}
    end
  end

  defp hash(token), do: :crypto.hash(:sha256, token)
end
