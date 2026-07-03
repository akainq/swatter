defmodule Swatter.Alerts.DeliveryTest do
  # async: false — мутируем Application env (:alerts) и Redis (cooldown)
  use Swatter.DataCase, async: false
  use Oban.Testing, repo: Swatter.Repo

  import Swatter.ProjectsFixtures

  alias Swatter.Alerts
  alias Swatter.Alerts.{NotifyWorker, Telegram}
  alias Swatter.Issues

  setup do
    prev = Application.get_env(:swatter, :alerts, [])
    on_exit(fn -> Application.put_env(:swatter, :alerts, prev) end)
    %{prev: prev}
  end

  defp with_token(prev, token \\ "BOT:TOKEN") do
    Application.put_env(:swatter, :alerts, Keyword.put(prev, :telegram_bot_token, token))
  end

  defp ok_stub! do
    parent = self()

    Req.Test.stub(Telegram, fn conn ->
      send(parent, :telegram_sent)
      Req.Test.json(conn, %{"ok" => true})
    end)
  end

  defp new_issue!(project, fp \\ nil) do
    {:ok, issue} = Issues.upsert_from_event(norm(fp), project.organization_id, project.id)
    issue
  end

  defp norm(fp) do
    now = DateTime.utc_now()

    %{
      fingerprint_hash: fp || "fp-#{System.unique_integer([:positive])}",
      grouping_version: 1,
      title: "Boom",
      culprit: "Mod.fun",
      level: "error",
      timestamp: now
    }
  end

  describe "Telegram.send_message/2" do
    test "нет токена → {:error, :no_token}", %{prev: prev} do
      Application.put_env(:swatter, :alerts, Keyword.put(prev, :telegram_bot_token, nil))
      assert {:error, :no_token} = Telegram.send_message("-100", "x")
    end

    test "ok:true → :ok, запрос уходит на /bot<token>/sendMessage", %{prev: prev} do
      with_token(prev)
      parent = self()

      Req.Test.stub(Telegram, fn conn ->
        send(parent, {:tg_path, conn.request_path})
        Req.Test.json(conn, %{"ok" => true})
      end)

      assert :ok = Telegram.send_message("-100", "hello")
      assert_received {:tg_path, "/botBOT:TOKEN/sendMessage"}
    end

    test "4xx → {:error, {:http, 400, _}} (для отмены ретрая)", %{prev: prev} do
      with_token(prev)

      Req.Test.stub(Telegram, fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{"ok" => false, "description" => "chat not found"})
      end)

      assert {:error, {:http, 400, _}} = Telegram.send_message("-100", "hello")
    end
  end

  describe "NotifyWorker.perform/1" do
    test "готовый проект → :ok и сообщение отправлено", %{prev: prev} do
      with_token(prev)
      {project, _} = project_fixture()
      {:ok, _} = Alerts.upsert_settings(project.id, %{telegram_chat_id: "-100"})
      issue = new_issue!(project)
      ok_stub!()

      assert :ok = perform_job(NotifyWorker, %{"issue_id" => issue.id, "rule" => "new_issue"})
      assert_received :telegram_sent
    end

    test "issue исчез → :ok без отправки" do
      assert :ok = perform_job(NotifyWorker, %{"issue_id" => 999_999, "rule" => "new_issue"})
    end

    test "канал не готов (нет chat_id) → :ok без отправки", %{prev: prev} do
      with_token(prev)
      {project, _} = project_fixture()
      issue = new_issue!(project)

      assert :ok = perform_job(NotifyWorker, %{"issue_id" => issue.id, "rule" => "new_issue"})
    end
  end

  describe "maybe_notify/1" do
    test "новый issue + правило вкл + канал готов → джоба поставлена", %{prev: prev} do
      with_token(prev)
      {project, _} = project_fixture()
      {:ok, _} = Alerts.upsert_settings(project.id, %{telegram_chat_id: "-100"})
      issue = new_issue!(project)
      assert issue.event_kind == "new"

      Alerts.maybe_notify(issue)

      assert_enqueued(
        worker: NotifyWorker,
        args: %{"issue_id" => issue.id, "rule" => "new_issue"}
      )
    end

    test "регрессия (resolved → новое событие) → джоба regression", %{prev: prev} do
      with_token(prev)
      {project, _} = project_fixture()
      {:ok, _} = Alerts.upsert_settings(project.id, %{telegram_chat_id: "-100"})

      fp = "fp-reg-#{System.unique_integer([:positive])}"
      issue = new_issue!(project, fp)
      {:ok, _} = Issues.update_status(issue, "resolved")
      {:ok, reopened} = Issues.upsert_from_event(norm(fp), project.organization_id, project.id)
      assert reopened.event_kind == "regression"

      Alerts.maybe_notify(reopened)

      assert_enqueued(
        worker: NotifyWorker,
        args: %{"issue_id" => reopened.id, "rule" => "regression"}
      )
    end

    test "правило выключено → нет джобы", %{prev: prev} do
      with_token(prev)
      {project, _} = project_fixture()

      {:ok, _} =
        Alerts.upsert_settings(project.id, %{telegram_chat_id: "-100", on_new_issue: false})

      issue = new_issue!(project)

      Alerts.maybe_notify(issue)
      refute_enqueued(worker: NotifyWorker)
    end

    test "канал не готов → нет джобы", %{prev: prev} do
      Application.put_env(:swatter, :alerts, Keyword.put(prev, :telegram_bot_token, nil))
      {project, _} = project_fixture()
      {:ok, _} = Alerts.upsert_settings(project.id, %{telegram_chat_id: "-100"})
      issue = new_issue!(project)

      Alerts.maybe_notify(issue)
      refute_enqueued(worker: NotifyWorker)
    end

    test "хост из тега server_name попадает в args джобы", %{prev: prev} do
      with_token(prev)
      {project, _} = project_fixture()
      {:ok, _} = Alerts.upsert_settings(project.id, %{telegram_chat_id: "-100"})
      Swatter.Alerts.SettingsCache.clear()

      normalized = Map.put(norm(nil), :tags, %{"server_name" => "web-01"})

      {:ok, issue} =
        Issues.upsert_from_event(normalized, project.organization_id, project.id)

      Alerts.on_event(issue, normalized)

      assert_enqueued(
        worker: NotifyWorker,
        args: %{"issue_id" => issue.id, "rule" => "new_issue", "host" => "web-01"}
      )
    end

    test "ongoing (повтор того же fingerprint) → нет джобы", %{prev: prev} do
      with_token(prev)
      {project, _} = project_fixture()
      {:ok, _} = Alerts.upsert_settings(project.id, %{telegram_chat_id: "-100"})

      fp = "fp-same-#{System.unique_integer([:positive])}"
      _first = new_issue!(project, fp)
      {:ok, second} = Issues.upsert_from_event(norm(fp), project.organization_id, project.id)
      assert second.event_kind == "ongoing"

      Alerts.maybe_notify(second)
      refute_enqueued(worker: NotifyWorker)
    end
  end

  describe "on_event/1 — порог частоты" do
    setup do
      Swatter.Alerts.SettingsCache.clear()
      :ok
    end

    test "алерт ровно на пороговом событии, не раньше и не дважды", %{prev: prev} do
      with_token(prev)
      {project, _} = project_fixture()

      {:ok, _} =
        Alerts.upsert_settings(project.id, %{
          telegram_chat_id: "-100",
          on_new_issue: false,
          on_regression: false,
          frequency_threshold: 3,
          frequency_window_seconds: 3600
        })

      fp = "fp-freq-#{System.unique_integer([:positive])}"

      {:ok, i1} = Issues.upsert_from_event(norm(fp), project.organization_id, project.id)
      Alerts.on_event(i1)
      {:ok, i2} = Issues.upsert_from_event(norm(fp), project.organization_id, project.id)
      Alerts.on_event(i2)
      refute_enqueued(worker: NotifyWorker)

      {:ok, i3} = Issues.upsert_from_event(norm(fp), project.organization_id, project.id)
      Alerts.on_event(i3)

      assert Enum.any?(
               all_enqueued(worker: NotifyWorker),
               &(&1.args["rule"] == "frequency" and &1.args["issue_id"] == i3.id)
             )

      {:ok, i4} = Issues.upsert_from_event(norm(fp), project.organization_id, project.id)
      Alerts.on_event(i4)

      freq = Enum.filter(all_enqueued(worker: NotifyWorker), &(&1.args["rule"] == "frequency"))
      assert length(freq) == 1
    end

    test "порог не задан → частотных джоб нет", %{prev: prev} do
      with_token(prev)
      {project, _} = project_fixture()

      {:ok, _} =
        Alerts.upsert_settings(project.id, %{telegram_chat_id: "-100", on_new_issue: false})

      fp = "fp-nofreq-#{System.unique_integer([:positive])}"

      for _ <- 1..5 do
        {:ok, issue} = Issues.upsert_from_event(norm(fp), project.organization_id, project.id)
        Alerts.on_event(issue)
      end

      refute Enum.any?(all_enqueued(worker: NotifyWorker), &(&1.args["rule"] == "frequency"))
    end
  end
end
