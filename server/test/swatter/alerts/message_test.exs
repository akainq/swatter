defmodule Swatter.Alerts.MessageTest do
  use Swatter.DataCase, async: true

  import Swatter.ProjectsFixtures

  alias Swatter.Alerts.Message
  alias Swatter.Issues

  test "содержит заголовок правила, тайтл, culprit и ссылку на issue" do
    {project, _} = project_fixture()

    {:ok, issue} =
      Issues.upsert_from_event(norm("Boom", "Mod.fun"), project.organization_id, project.id)

    issue = Issues.get_issue(issue.id)

    text = Message.build(issue, "new_issue")

    assert text =~ "Новый issue"
    assert text =~ "Boom"
    assert text =~ "Mod.fun"
    assert text =~ "/issues/#{issue.id}"
  end

  test "regression-заголовок и AI-резюме, если передано" do
    {project, _} = project_fixture()

    {:ok, issue} =
      Issues.upsert_from_event(norm("Boom", "Mod.fun"), project.organization_id, project.id)

    issue = Issues.get_issue(issue.id)

    text = Message.build(issue, "regression", ai_summary: "nil pointer in checkout")

    assert text =~ "Регрессия"
    assert text =~ "nil pointer in checkout"
  end

  defp norm(title, culprit) do
    now = DateTime.utc_now()

    %{
      fingerprint_hash: "fp-#{System.unique_integer([:positive])}",
      grouping_version: 1,
      title: title,
      culprit: culprit,
      level: "error",
      timestamp: now
    }
  end
end
