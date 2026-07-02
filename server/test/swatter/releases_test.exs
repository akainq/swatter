defmodule Swatter.ReleasesTest do
  use Swatter.DataCase, async: true

  import Swatter.EventFixtures
  import Swatter.ProjectsFixtures

  alias Swatter.{Issues, Releases}
  alias Swatter.Pipeline.Normalizer

  @at ~U[2026-07-02 12:00:00.000000Z]

  defp normalized(overrides \\ %{}) do
    Normalizer.normalize(bun_event(overrides), @at)
  end

  describe "get_or_create/3" do
    test "создаёт релиз и назначает возрастающий ordinal" do
      {project, _} = project_fixture()

      r1 = Releases.get_or_create(project.id, "v1.0", @at)
      r2 = Releases.get_or_create(project.id, "v2.0", @at)
      r1_again = Releases.get_or_create(project.id, "v1.0", @at)

      assert r1.ordinal == 1
      assert r2.ordinal == 2
      assert r1_again.id == r1.id
    end

    test "nil/пустая версия → nil" do
      {project, _} = project_fixture()
      assert Releases.get_or_create(project.id, nil, @at) == nil
      assert Releases.get_or_create(project.id, "", @at) == nil
    end

    test "ordinal независим по проектам" do
      {p1, _} = project_fixture()
      {p2, _} = project_fixture()
      assert Releases.get_or_create(p1.id, "x", @at).ordinal == 1
      assert Releases.get_or_create(p2.id, "x", @at).ordinal == 1
    end
  end

  describe "regression через upsert_from_event" do
    setup do
      {project, _} = project_fixture()
      %{project: project}
    end

    test "первое событие привязывает issue к first_release", %{project: project} do
      release = Releases.get_or_create(project.id, "v1.0", @at)
      n = normalized(%{"release" => "v1.0"})

      {:ok, issue} = Issues.upsert_from_event(n, project.organization_id, project.id, release)
      assert issue.first_release_id == release.id
      refute issue.regressed
    end

    test "resolved в старом релизе, событие в новом → regression + reopen", %{project: project} do
      r1 = Releases.get_or_create(project.id, "v1.0", @at)
      n = normalized(%{"release" => "v1.0"})
      {:ok, issue} = Issues.upsert_from_event(n, project.organization_id, project.id, r1)

      # закрываем, когда v1.0 — последний релиз (resolved_in_release = v1.0)
      {:ok, resolved} = Issues.update_status(issue, "resolved")
      assert resolved.status == "resolved"

      # позже появляется v2.0, и событие приходит в нём (новее v1.0)
      r2 = Releases.get_or_create(project.id, "v2.0", @at)
      n2 = normalized(%{"release" => "v2.0"})
      {:ok, reopened} = Issues.upsert_from_event(n2, project.organization_id, project.id, r2)

      assert reopened.status == "unresolved"
      assert reopened.regressed
    end

    test "событие в том же релизе, где закрыли → reopen без флага regression", %{
      project: project
    } do
      r1 = Releases.get_or_create(project.id, "v1.0", @at)
      n = normalized(%{"release" => "v1.0"})
      {:ok, issue} = Issues.upsert_from_event(n, project.organization_id, project.id, r1)
      {:ok, _resolved} = Issues.update_status(issue, "resolved")

      {:ok, reopened} = Issues.upsert_from_event(n, project.organization_id, project.id, r1)
      assert reopened.status == "unresolved"
      refute reopened.regressed
    end

    test "unresolve/ignore снимает флаг regression", %{project: project} do
      r1 = Releases.get_or_create(project.id, "v1.0", @at)
      n = normalized(%{"release" => "v1.0"})
      {:ok, issue} = Issues.upsert_from_event(n, project.organization_id, project.id, r1)
      {:ok, _} = issue |> Ecto.Changeset.change(regressed: true) |> Repo.update()

      {:ok, ignored} = Issues.update_status(%{issue | regressed: true}, "ignored")
      refute ignored.regressed
    end
  end

  describe "list/detail" do
    test "list со счётчиком новых issues; new_issues по релизу", %{} do
      {project, _} = project_fixture()
      r1 = Releases.get_or_create(project.id, "v1.0", @at)

      for fp <- ["a", "b"] do
        n = normalized(%{"release" => "v1.0", "fingerprint" => [fp]})
        {:ok, _} = Issues.upsert_from_event(n, project.organization_id, project.id, r1)
      end

      [entry] = Releases.list_releases_with_counts(project.id)
      assert entry.release.version == "v1.0"
      assert entry.new_issues == 2

      assert length(Releases.new_issues(r1)) == 2
    end
  end
end
