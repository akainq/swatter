defmodule Swatter.EventsRepo do
  @moduledoc """
  ClickHouse-репозиторий для событий (ADR-0003). Только батч-вставки из
  пайплайна и аналитические чтения; UPDATE/DELETE по строкам не бывает.
  """

  use Ecto.Repo, otp_app: :swatter, adapter: Ecto.Adapters.ClickHouse
end
