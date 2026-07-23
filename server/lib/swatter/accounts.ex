defmodule Swatter.Accounts do
  @moduledoc """
  Пользователи, membership'ы и сессии dashboard (ADR-0007).
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Swatter.Accounts.{Membership, User, UserToken}
  alias Swatter.Projects.Organization
  alias Swatter.Repo

  ## Первый запуск

  @doc "true, если в системе ещё нет ни одного пользователя."
  def setup_required? do
    not Repo.exists?(User)
  end

  @doc """
  Первый запуск (ADR-0007): создаёт owner-пользователя и организацию
  одной транзакцией. Отказывает, если пользователи уже есть.
  """
  def bootstrap(attrs) do
    org_name = attrs["orgName"] || attrs[:org_name] || "Swatter"
    org_slug = attrs["orgSlug"] || attrs[:org_slug] || "swatter"

    Multi.new()
    |> Multi.run(:guard, fn repo, _ ->
      if repo.exists?(User), do: {:error, :already_set_up}, else: {:ok, :empty}
    end)
    |> Multi.insert(:user, User.registration_changeset(%User{}, attrs))
    |> Multi.run(:organization, fn repo, _ ->
      case repo.get_by(Organization, slug: org_slug) do
        # организация могла быть создана сидами до первого пользователя
        nil ->
          repo.insert(Organization.changeset(%Organization{}, %{name: org_name, slug: org_slug}))

        org ->
          {:ok, org}
      end
    end)
    |> Multi.insert(:membership, fn %{user: user, organization: org} ->
      %Membership{user_id: user.id, organization_id: org.id, role: "owner"}
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{user: user, organization: org}} -> {:ok, user, org}
      {:error, :guard, :already_set_up, _} -> {:error, :already_set_up}
      {:error, _step, changeset, _} -> {:error, changeset}
    end
  end

  ## Пользователи и пароли

  def get_user_by_email(email) when is_binary(email) do
    Repo.get_by(User, email: String.downcase(email))
  end

  def get_user_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    user = get_user_by_email(email)
    if User.valid_password?(user, password), do: user
  end

  def register_user(attrs) do
    %User{} |> User.registration_changeset(attrs) |> Repo.insert()
  end

  @doc "Сброс пароля админом сервера (mix swatter.reset_password): режет все сессии."
  def reset_password(%User{} = user, new_password) do
    Multi.new()
    |> Multi.update(:user, User.registration_changeset(user, %{password: new_password}))
    |> Multi.delete_all(:tokens, from(t in UserToken, where: t.user_id == ^user.id))
    |> Repo.transaction()
    |> case do
      {:ok, %{user: user}} -> {:ok, user}
      {:error, _step, changeset, _} -> {:error, changeset}
    end
  end

  ## Сессии

  def create_session_token(%User{} = user) do
    {encoded, token} = UserToken.build_session_token(user)
    Repo.insert!(token)
    encoded
  end

  def get_user_by_session_token(encoded_token) when is_binary(encoded_token) do
    case UserToken.verify_session_token_query(encoded_token) do
      {:ok, query} -> Repo.one(query)
      :error -> nil
    end
  end

  def get_user_by_session_token(_), do: nil

  def delete_session_token(encoded_token) when is_binary(encoded_token) do
    case UserToken.by_raw_token_query(encoded_token) do
      {:ok, query} -> Repo.delete_all(query)
      :error -> :ok
    end

    :ok
  end

  def delete_session_token(_), do: :ok

  ## API-токены (ADR-0017)

  @doc "Создаёт API-токен; плейнтекст `swt_...` возвращается один раз."
  def create_api_token(%User{} = user, name) when is_binary(name) and name != "" do
    {plaintext, token} = UserToken.build_api_token(user, name)
    {:ok, record} = Repo.insert(token)
    {:ok, plaintext, record}
  end

  def create_api_token(%User{}, _name), do: {:error, :invalid_name}

  def list_api_tokens(%User{id: user_id}) do
    Repo.all(
      from t in UserToken,
        where: t.user_id == ^user_id and t.context == "api",
        order_by: [desc: t.id]
    )
  end

  @doc "Ревокация своего токена; чужой/несуществующий — {:error, :not_found}."
  def delete_api_token(%User{id: user_id}, token_id) do
    case Repo.get_by(UserToken, id: token_id, user_id: user_id, context: "api") do
      nil -> {:error, :not_found}
      token -> Repo.delete(token)
    end
  end

  def get_user_by_api_token(raw) when is_binary(raw) do
    case UserToken.verify_api_token_query(raw) do
      {:ok, query} -> Repo.one(query)
      :error -> nil
    end
  end

  def get_user_by_api_token(_), do: nil

  ## Membership

  def add_member(%User{id: user_id}, %Organization{id: org_id}, role \\ "member") do
    %Membership{user_id: user_id, organization_id: org_id}
    |> Membership.changeset(%{role: role})
    |> Repo.insert()
  end

  def member?(%User{id: user_id}, org_id) when is_integer(org_id) do
    Repo.exists?(
      from m in Membership, where: m.user_id == ^user_id and m.organization_id == ^org_id
    )
  end

  def member?(_, _), do: false

  @doc "Организации пользователя (для списка в API)."
  def list_organizations_for(%User{id: user_id}) do
    Repo.all(
      from o in Organization,
        join: m in Membership,
        on: m.organization_id == o.id,
        where: m.user_id == ^user_id,
        order_by: o.slug
    )
  end

  def list_memberships(%User{id: user_id}) do
    Repo.all(
      from m in Membership,
        where: m.user_id == ^user_id,
        preload: [:organization],
        order_by: m.id
    )
  end
end
