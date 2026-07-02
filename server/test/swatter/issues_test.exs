defmodule Swatter.IssuesTest do
  use Swatter.DataCase, async: true

  import Swatter.EventFixtures
  import Swatter.ProjectsFixtures

  alias Swatter.Issues
  alias Swatter.Pipeline.Normalizer

  @received_at ~U[2026-07-02 12:00:00.000000Z]

  defp normalized(overrides \\ %{}) do
    Normalizer.normalize(bun_event(overrides), @received_at)
  end

  test "первое событие создаёт issue" do
    {project, _key} = project_fixture()
    n = normalized()

    assert {:ok, issue} = Issues.upsert_from_event(n, project.organization_id, project.id)
    assert issue.times_seen == 1
    assert issue.status == "unresolved"
    assert issue.title == "Error: conformance: hello from @sentry/bun"
    assert issue.first_seen == n.timestamp
    assert issue.last_seen == n.timestamp
  end

  test "повторное событие инкрементит счётчик и сдвигает last_seen" do
    {project, _key} = project_fixture()
    n1 = normalized()
    later = %{n1 | timestamp: DateTime.add(n1.timestamp, 60, :second)}

    {:ok, first} = Issues.upsert_from_event(n1, project.organization_id, project.id)
    {:ok, second} = Issues.upsert_from_event(later, project.organization_id, project.id)

    assert second.id == first.id
    assert second.times_seen == 2
    assert second.first_seen == n1.timestamp
    assert second.last_seen == later.timestamp
  end

  test "события из прошлого не откатывают last_seen назад" do
    {project, _key} = project_fixture()
    n = normalized()
    earlier = %{n | timestamp: DateTime.add(n.timestamp, -3600, :second)}

    {:ok, _} = Issues.upsert_from_event(n, project.organization_id, project.id)
    {:ok, issue} = Issues.upsert_from_event(earlier, project.organization_id, project.id)

    assert issue.last_seen == n.timestamp
  end

  test "resolved-issue переоткрывается новым событием" do
    {project, _key} = project_fixture()
    n = normalized()

    {:ok, issue} = Issues.upsert_from_event(n, project.organization_id, project.id)
    {:ok, _} = issue |> Ecto.Changeset.change(status: "resolved") |> Repo.update()

    {:ok, reopened} = Issues.upsert_from_event(n, project.organization_id, project.id)
    assert reopened.status == "unresolved"
  end

  test "ignored-issue не переоткрывается" do
    {project, _key} = project_fixture()
    n = normalized()

    {:ok, issue} = Issues.upsert_from_event(n, project.organization_id, project.id)
    {:ok, _} = issue |> Ecto.Changeset.change(status: "ignored") |> Repo.update()

    {:ok, still_ignored} = Issues.upsert_from_event(n, project.organization_id, project.id)
    assert still_ignored.status == "ignored"
  end

  test "разные fingerprint — разные issues в одном проекте" do
    {project, _key} = project_fixture()
    a = normalized()
    b = normalized(%{"fingerprint" => ["totally-different"]})

    {:ok, ia} = Issues.upsert_from_event(a, project.organization_id, project.id)
    {:ok, ib} = Issues.upsert_from_event(b, project.organization_id, project.id)

    refute ia.id == ib.id
  end

  test "одинаковый fingerprint в разных проектах — разные issues" do
    {p1, _} = project_fixture()
    {p2, _} = project_fixture()
    n = normalized()

    {:ok, i1} = Issues.upsert_from_event(n, p1.organization_id, p1.id)
    {:ok, i2} = Issues.upsert_from_event(n, p2.organization_id, p2.id)

    refute i1.id == i2.id
  end
end
