defmodule Swatter.Repo.Migrations.AddNameToUserTokens do
  use Ecto.Migration

  # API-токены swt_ (ADR-0017, отложено из ADR-0007) живут в той же таблице
  # с context: "api"; name — подпись токена для списка в UI
  def change do
    alter table(:user_tokens) do
      add :name, :string
    end
  end
end
