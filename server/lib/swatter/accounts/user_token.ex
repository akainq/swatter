defmodule Swatter.Accounts.UserToken do
  @moduledoc """
  Токены пользователя. В БД — только SHA-256 от сырого токена: утечка БД
  не даёт ни сессий, ни API-доступа. Контексты:

  - `"session"` — cookie-сессии dashboard (ADR-0007), TTL 60 дней;
  - `"api"` — API-токены `swt_*` для MCP/автоматизации (ADR-0017),
    без TTL (только ревокация), с именем для списка в UI.
  """

  use Ecto.Schema

  import Ecto.Query

  @rand_size 32
  @session_validity_days 60
  @api_prefix "swt_"

  schema "user_tokens" do
    field :token_hash, :binary
    field :context, :string
    field :name, :string

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

  ## API-токены (ADR-0017)

  @doc "Возвращает {\"swt_...\" для показа один раз, struct для вставки}."
  def build_api_token(user, name) do
    token = :crypto.strong_rand_bytes(@rand_size)

    {@api_prefix <> Base.url_encode64(token, padding: false),
     %__MODULE__{token_hash: hash(token), context: "api", name: name, user_id: user.id}}
  end

  @doc "Запрос пользователя по сырому `swt_`-токену (nil-безопасно на вызывающей стороне)."
  def verify_api_token_query(@api_prefix <> encoded) do
    with {:ok, token} <- Base.url_decode64(encoded, padding: false) do
      query =
        from t in __MODULE__,
          where: t.token_hash == ^hash(token) and t.context == "api",
          join: u in assoc(t, :user),
          select: u

      {:ok, query}
    end
  end

  def verify_api_token_query(_), do: :error

  defp hash(token), do: :crypto.hash(:sha256, token)
end
