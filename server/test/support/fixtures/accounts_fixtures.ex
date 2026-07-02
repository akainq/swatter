defmodule Swatter.AccountsFixtures do
  @moduledoc false

  alias Swatter.Accounts

  def valid_password, do: "correct horse battery"

  def user_fixture(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, user} =
      attrs
      |> Enum.into(%{
        "email" => "user-#{n}@example.com",
        "name" => "User #{n}",
        "password" => valid_password()
      })
      |> Accounts.register_user()

    user
  end

  @doc "Пользователь-участник организации."
  def member_fixture(org, role \\ "member") do
    user = user_fixture()
    {:ok, _} = Accounts.add_member(user, org, role)
    user
  end
end
