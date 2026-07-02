defmodule Swatter.AlertsTest do
  # async: false — часть тестов мутирует Application env (:alerts)
  use Swatter.DataCase, async: false

  import Swatter.ProjectsFixtures

  alias Swatter.Alerts
  alias Swatter.Alerts.Settings

  describe "get_settings/1" do
    test "возвращает дефолты для проекта без записи" do
      {project, _key} = project_fixture()
      settings = Alerts.get_settings(project.id)

      assert %Settings{} = settings
      assert settings.id == nil
      assert settings.on_new_issue
      assert settings.on_regression
      refute settings.ai_enabled
      assert settings.telegram_chat_id == nil
    end
  end

  describe "upsert_settings/2" do
    test "создаёт, затем обновляет одну строку на проект" do
      {project, _key} = project_fixture()

      {:ok, s1} =
        Alerts.upsert_settings(project.id, %{
          telegram_chat_id: "-100123",
          on_regression: false,
          ai_enabled: true
        })

      assert s1.id
      assert s1.telegram_chat_id == "-100123"
      refute s1.on_regression
      assert s1.ai_enabled

      {:ok, s2} = Alerts.upsert_settings(project.id, %{telegram_chat_id: "-100999"})
      assert s2.id == s1.id
      assert s2.telegram_chat_id == "-100999"

      assert Alerts.get_settings(project.id).id == s1.id
    end

    test "валидирует положительный порог частоты" do
      {project, _key} = project_fixture()

      assert {:error, changeset} =
               Alerts.upsert_settings(project.id, %{frequency_threshold: 0})

      assert %{frequency_threshold: ["must be greater than 0"]} = errors_on(changeset)
    end
  end

  describe "telegram_ready?/1" do
    setup do
      prev = Application.get_env(:swatter, :alerts, [])
      on_exit(fn -> Application.put_env(:swatter, :alerts, prev) end)
      %{prev: prev}
    end

    test "false без bot-token в конфиге", %{prev: prev} do
      Application.put_env(:swatter, :alerts, Keyword.put(prev, :telegram_bot_token, nil))
      refute Alerts.telegram_ready?(%Settings{enabled: true, telegram_chat_id: "-100123"})
    end

    test "true только при токене + chat_id + enabled", %{prev: prev} do
      Application.put_env(:swatter, :alerts, Keyword.put(prev, :telegram_bot_token, "123:abc"))

      assert Alerts.telegram_ready?(%Settings{enabled: true, telegram_chat_id: "-100123"})
      refute Alerts.telegram_ready?(%Settings{enabled: false, telegram_chat_id: "-100123"})
      refute Alerts.telegram_ready?(%Settings{enabled: true, telegram_chat_id: nil})
      refute Alerts.telegram_ready?(%Settings{enabled: true, telegram_chat_id: ""})
    end
  end
end
