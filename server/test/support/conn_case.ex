defmodule SwatterWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use SwatterWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint SwatterWeb.Endpoint

      use SwatterWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import SwatterWeb.ConnCase
    end
  end

  setup tags do
    Swatter.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc "Кладёт сессионный токен пользователя в тестовую сессию conn."
  def log_in_user(conn, user) do
    token = Swatter.Accounts.create_session_token(user)
    Plug.Test.init_test_session(conn, %{user_token: token})
  end
end
