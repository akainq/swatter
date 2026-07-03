defmodule SwatterWeb.AlertsAiApiTest do
  # async: false — мутируем Application env (:ai)
  use SwatterWeb.ConnCase, async: false
  use Oban.Testing, repo: Swatter.Repo

  import OpenApiSpex.TestAssertions
  import Swatter.AccountsFixtures
  import Swatter.ProjectsFixtures

  alias Swatter.AI
  alias Swatter.Issues

  setup %{conn: conn} do
    {project, _key} = project_fixture()
    org = Swatter.Repo.get!(Swatter.Projects.Organization, project.organization_id)
    user = member_fixture(org)

    prev = Application.get_env(:swatter, :ai, [])
    on_exit(fn -> Application.put_env(:swatter, :ai, prev) end)

    %{conn: log_in_user(conn, user), org: org, project: project, prev: prev}
  end

  defp api_spec, do: SwatterWeb.ApiSpec.spec()

  defp create_issue!(project) do
    {:ok, issue} =
      Issues.upsert_from_event(
        %{
          fingerprint_hash: "fp-api-#{System.unique_integer([:positive])}",
          grouping_version: 1,
          title: "Boom",
          culprit: "Mod.fun",
          level: "error",
          timestamp: DateTime.utc_now()
        },
        project.organization_id,
        project.id
      )

    issue
  end

  describe "GET /api/0/projects/:org/:proj/alert-settings" do
    test "дефолты для проекта без записи", %{conn: conn, org: org, project: project} do
      conn = get(conn, "/api/0/projects/#{org.slug}/#{project.slug}/alert-settings")
      body = json_response(conn, 200)

      assert body["onNewIssue"] == true
      assert body["onRegression"] == true
      assert body["telegramChatId"] == nil
      assert body["frequencyThreshold"] == nil
      assert is_boolean(body["telegramConfigured"])
      assert_schema(body, "AlertSettings", api_spec())
    end

    test "чужая организация → 404", %{conn: _conn, org: _org, project: project} do
      other_user = member_fixture(org_fixture())
      conn = log_in_user(Phoenix.ConnTest.build_conn(), other_user)

      org = Swatter.Repo.get!(Swatter.Projects.Organization, project.organization_id)
      conn = get(conn, "/api/0/projects/#{org.slug}/#{project.slug}/alert-settings")
      assert json_response(conn, 404)
    end
  end

  describe "PUT /api/0/projects/:org/:proj/alert-settings" do
    test "частичное обновление сохраняется", %{conn: conn, org: org, project: project} do
      conn =
        put(conn, "/api/0/projects/#{org.slug}/#{project.slug}/alert-settings", %{
          "telegramChatId" => "146075783",
          "frequencyThreshold" => 10,
          "onRegression" => false
        })

      body = json_response(conn, 200)
      assert body["telegramChatId"] == "146075783"
      assert body["frequencyThreshold"] == 10
      assert body["onRegression"] == false
      # не присланное поле не тронуто
      assert body["onNewIssue"] == true
      assert_schema(body, "AlertSettings", api_spec())

      # сохранилось в БД
      assert Swatter.Alerts.get_settings(project.id).telegram_chat_id == "146075783"
    end

    test "невалидный порог → 400", %{conn: conn, org: org, project: project} do
      conn =
        put(conn, "/api/0/projects/#{org.slug}/#{project.slug}/alert-settings", %{
          "frequencyThreshold" => 0
        })

      assert %{"detail" => detail} = json_response(conn, 400)
      assert detail =~ "frequency_threshold"
    end
  end

  describe "POST /api/0/issues/:id/analyze" do
    test "AI не настроен → 422", %{conn: conn, project: project, prev: prev} do
      Application.put_env(:swatter, :ai, Keyword.put(prev, :api_key, nil))
      issue = create_issue!(project)

      conn = post(conn, "/api/0/issues/#{issue.id}/analyze")
      assert %{"detail" => detail} = json_response(conn, 422)
      assert detail =~ "ZAI_API_KEY"
    end

    test "с ключом → 202 pending + джоба", %{conn: conn, project: project, prev: prev} do
      Application.put_env(:swatter, :ai, Keyword.put(prev, :api_key, "zai-test"))
      issue = create_issue!(project)

      conn = post(conn, "/api/0/issues/#{issue.id}/analyze")
      body = json_response(conn, 202)
      assert body["status"] == "pending"
      assert_schema(body, "AIAnalysis", api_spec())

      assert_enqueued(
        worker: Swatter.AI.AnalyzeIssueWorker,
        args: %{"issue_id" => issue.id}
      )
    end

    test "чужой issue → 404", %{project: project, prev: prev} do
      Application.put_env(:swatter, :ai, Keyword.put(prev, :api_key, "zai-test"))
      issue = create_issue!(project)

      other_user = member_fixture(org_fixture())
      conn = log_in_user(Phoenix.ConnTest.build_conn(), other_user)

      conn = post(conn, "/api/0/issues/#{issue.id}/analyze")
      assert json_response(conn, 404)
    end
  end

  describe "GET /api/0/issues/:id (aiAnalysis в деталке)" do
    test "без анализа → null + aiEnabled", %{conn: conn, project: project} do
      issue = create_issue!(project)

      body = conn |> get("/api/0/issues/#{issue.id}") |> json_response(200)
      assert body["aiAnalysis"] == nil
      assert is_boolean(body["aiEnabled"])
      assert_schema(body, "Issue", api_spec())
    end

    test "готовый анализ отдаётся в деталке", %{conn: conn, project: project} do
      issue = create_issue!(project)

      {:ok, _} =
        AI.store_ok(
          issue.id,
          %{
            summary: "Разыменование nil",
            probable_cause: "user не инициализирован",
            severity: "high",
            suggested_fix: "optional chaining"
          },
          "glm-4.6"
        )

      body = conn |> get("/api/0/issues/#{issue.id}") |> json_response(200)
      assert body["aiAnalysis"]["status"] == "ok"
      assert body["aiAnalysis"]["summary"] == "Разыменование nil"
      assert body["aiAnalysis"]["severity"] == "high"
      assert body["aiAnalysis"]["model"] == "glm-4.6"
      assert_schema(body, "Issue", api_spec())
    end
  end
end
