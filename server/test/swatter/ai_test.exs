defmodule Swatter.AITest do
  # async: false — мутируем Application env (:ai)
  use Swatter.DataCase, async: false
  use Oban.Testing, repo: Swatter.Repo

  import Swatter.ProjectsFixtures

  alias Swatter.AI
  alias Swatter.AI.{AnalyzeIssueWorker, ZAI}
  alias Swatter.Issues

  setup do
    prev = Application.get_env(:swatter, :ai, [])
    on_exit(fn -> Application.put_env(:swatter, :ai, prev) end)
    %{prev: prev}
  end

  defp with_key(prev, key \\ "zai-test-key") do
    Application.put_env(:swatter, :ai, Keyword.put(prev, :api_key, key))
  end

  defp new_issue! do
    {project, _} = project_fixture()

    {:ok, issue} =
      Issues.upsert_from_event(
        %{
          fingerprint_hash: "fp-ai-#{System.unique_integer([:positive])}",
          grouping_version: 1,
          title: "TypeError: Cannot read properties of undefined (reading 'user')",
          culprit: "checkout.ts in submitOrder",
          level: "error",
          timestamp: DateTime.utc_now()
        },
        project.organization_id,
        project.id
      )

    issue
  end

  defp stub_zai_json(map) do
    Req.Test.stub(ZAI, fn conn ->
      Req.Test.json(conn, %{
        "choices" => [%{"message" => %{"content" => Jason.encode!(map)}}]
      })
    end)
  end

  @valid_result %{
    "summary" => "Обращение к полю user у undefined-объекта",
    "probable_cause" => "Ответ API пришёл без поля user",
    "severity" => "high",
    "suggested_fix" => "Проверять наличие user перед обращением"
  }

  describe "request_analysis/1" do
    test "без ключа → {:error, :ai_disabled}, ничего не ставится", %{prev: prev} do
      Application.put_env(:swatter, :ai, Keyword.put(prev, :api_key, nil))
      issue = new_issue!()

      assert {:error, :ai_disabled} = AI.request_analysis(issue)
      refute_enqueued(worker: AnalyzeIssueWorker)
      assert AI.get_analysis(issue.id) == nil
    end

    test "с ключом → pending-строка + джоба", %{prev: prev} do
      with_key(prev)
      issue = new_issue!()

      assert {:ok, analysis} = AI.request_analysis(issue)
      assert analysis.status == "pending"
      assert_enqueued(worker: AnalyzeIssueWorker, args: %{"issue_id" => issue.id})
    end
  end

  describe "AnalyzeIssueWorker.perform/1" do
    test "валидный JSON от модели → status ok, поля сохранены", %{prev: prev} do
      with_key(prev)
      issue = new_issue!()
      stub_zai_json(@valid_result)

      assert :ok = perform_job(AnalyzeIssueWorker, %{"issue_id" => issue.id})

      analysis = AI.get_analysis(issue.id)
      assert analysis.status == "ok"
      assert analysis.summary == @valid_result["summary"]
      assert analysis.probable_cause == @valid_result["probable_cause"]
      assert analysis.severity == "high"
      assert analysis.suggested_fix == @valid_result["suggested_fix"]
      assert analysis.model == ZAI.model()
      assert analysis.analyzed_at
    end

    test "невалидный ответ модели → status error + ретрай", %{prev: prev} do
      with_key(prev)
      issue = new_issue!()

      Req.Test.stub(ZAI, fn conn ->
        Req.Test.json(conn, %{"choices" => [%{"message" => %{"content" => "не JSON"}}]})
      end)

      assert {:error, :invalid_response} =
               perform_job(AnalyzeIssueWorker, %{"issue_id" => issue.id})

      assert AI.get_analysis(issue.id).status == "error"
    end

    test "4xx от z.ai (плохой ключ) → {:cancel}, ретрая нет", %{prev: prev} do
      with_key(prev)
      issue = new_issue!()

      Req.Test.stub(ZAI, fn conn ->
        conn
        |> Plug.Conn.put_status(401)
        |> Req.Test.json(%{"error" => %{"message" => "invalid api key"}})
      end)

      assert {:cancel, _} = perform_job(AnalyzeIssueWorker, %{"issue_id" => issue.id})
      assert AI.get_analysis(issue.id).status == "error"
    end

    test "issue исчез → :ok без вызова z.ai" do
      assert :ok = perform_job(AnalyzeIssueWorker, %{"issue_id" => 999_999})
    end
  end

  describe "parse_result/1" do
    test "терпит markdown-обёртку и нормализует severity" do
      wrapped =
        "```json\n" <> Jason.encode!(%{@valid_result | "severity" => "CRITICAL"}) <> "\n```"

      assert {:ok, fields} = AI.parse_result(wrapped)
      assert fields.severity == "critical"
    end

    test "мусорный severity → medium, пустой summary → ошибка" do
      assert {:ok, %{severity: "medium"}} =
               AI.parse_result(Jason.encode!(%{@valid_result | "severity" => "urgent!!"}))

      assert {:error, :invalid_response} =
               AI.parse_result(Jason.encode!(%{"summary" => ""}))

      assert {:error, :invalid_response} = AI.parse_result("plain text")
    end
  end
end
