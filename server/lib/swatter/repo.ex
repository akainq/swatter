defmodule Swatter.Repo do
  use Ecto.Repo,
    otp_app: :swatter,
    adapter: Ecto.Adapters.Postgres
end
