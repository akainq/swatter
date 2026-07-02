defmodule Swatter.ArtifactsTest do
  use Swatter.DataCase, async: true

  import Swatter.ProjectsFixtures

  alias Swatter.Artifacts

  test "put сжимает и хранит, fetch распаковывает" do
    {project, _} = project_fixture()
    content = String.duplicate("{\"version\":3,\"mappings\":\"AAAA\"}", 100)

    {:ok, bundle} = Artifacts.put(project.id, "ABCD-1234", "source_map", content, "app.js.map")

    assert bundle.debug_id == "abcd1234"
    assert bundle.content_size == byte_size(content)
    assert bundle.compressed_size < bundle.content_size
    assert Artifacts.fetch_source_map(project.id, "abcd1234") == content
  end

  test "повторная загрузка того же (project, debug_id, type) заменяет" do
    {project, _} = project_fixture()
    {:ok, _} = Artifacts.put(project.id, "dup", "source_map", "old")
    {:ok, _} = Artifacts.put(project.id, "dup", "source_map", "new content")

    assert Artifacts.fetch_source_map(project.id, "dup") == "new content"
  end

  test "debug_id матчится без дефисов и регистра" do
    {project, _} = project_fixture()
    {:ok, _} = Artifacts.put(project.id, "AB-CD", "source_map", "x")

    assert Artifacts.fetch_source_map(project.id, "abcd") == "x"
    assert Artifacts.fetch_source_map(project.id, "AB-CD") == "x"
  end

  test "fetch nil для чужого проекта и неизвестного debug_id" do
    {project, _} = project_fixture()
    {other, _} = project_fixture()
    {:ok, _} = Artifacts.put(project.id, "d1", "source_map", "x")

    assert Artifacts.fetch_source_map(other.id, "d1") == nil
    assert Artifacts.fetch_source_map(project.id, "unknown") == nil
  end
end
