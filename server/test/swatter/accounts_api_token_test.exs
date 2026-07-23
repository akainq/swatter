defmodule Swatter.AccountsApiTokenTest do
  use Swatter.DataCase, async: true

  import Swatter.AccountsFixtures
  import Swatter.ProjectsFixtures

  alias Swatter.Accounts

  defp user! do
    member_fixture(org_fixture())
  end

  test "create → swt_-префикс, verify возвращает владельца" do
    user = user!()
    {:ok, plaintext, record} = Accounts.create_api_token(user, "mcp")

    assert String.starts_with?(plaintext, "swt_")
    assert record.context == "api"
    assert record.name == "mcp"

    assert Accounts.get_user_by_api_token(plaintext).id == user.id
  end

  test "мусор, чужой формат и сессионный токен не аутентифицируют" do
    user = user!()
    session = Accounts.create_session_token(user)

    assert Accounts.get_user_by_api_token("swt_not-base64!!") == nil
    assert Accounts.get_user_by_api_token("swt_" <> Base.url_encode64("wrong")) == nil

    # сессионный токен без префикса не подходит к API-контексту
    assert Accounts.get_user_by_api_token(session) == nil
    assert Accounts.get_user_by_api_token(nil) == nil
  end

  test "list показывает только API-токены, delete ревокует только свои" do
    user = user!()
    other = user!()
    _session = Accounts.create_session_token(user)
    {:ok, plaintext, record} = Accounts.create_api_token(user, "mine")

    assert [%{id: id}] = Accounts.list_api_tokens(user)
    assert id == record.id

    assert {:error, :not_found} = Accounts.delete_api_token(other, record.id)
    assert {:ok, _} = Accounts.delete_api_token(user, record.id)
    assert Accounts.get_user_by_api_token(plaintext) == nil
  end

  test "пустое имя отклоняется" do
    assert {:error, :invalid_name} = Accounts.create_api_token(user!(), "")
  end
end
