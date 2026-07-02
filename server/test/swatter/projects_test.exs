defmodule Swatter.ProjectsTest do
  use Swatter.DataCase, async: true

  import Swatter.ProjectsFixtures

  alias Swatter.Projects
  alias Swatter.Projects.ProjectKey

  describe "create_organization/1" do
    test "создаёт организацию" do
      assert {:ok, org} = Projects.create_organization(%{name: "Acme", slug: "acme"})
      assert org.slug == "acme"
    end

    test "отклоняет невалидный slug" do
      assert {:error, changeset} = Projects.create_organization(%{name: "X", slug: "Не Слаг"})
      assert %{slug: _} = errors_on(changeset)
    end

    test "slug уникален" do
      {:ok, _} = Projects.create_organization(%{name: "A", slug: "dup"})
      assert {:error, changeset} = Projects.create_organization(%{name: "B", slug: "dup"})
      assert %{slug: _} = errors_on(changeset)
    end
  end

  describe "create_project/2" do
    test "создаёт проект сразу с активным DSN-ключом" do
      org = org_fixture()
      assert {:ok, project, key} = Projects.create_project(org, %{name: "App", slug: "app"})
      assert project.organization_id == org.id
      assert key.project_id == project.id
      assert key.active
      assert key.public_key =~ ~r/^[0-9a-f]{32}$/
    end
  end

  describe "get_active_key/2" do
    test "находит активный ключ своего проекта" do
      {project, key} = project_fixture()
      found = Projects.get_active_key(project.id, key.public_key)
      assert found.id == key.id
    end

    test "nil для чужого проекта" do
      {_project, key} = project_fixture()
      {other, _} = project_fixture()
      assert Projects.get_active_key(other.id, key.public_key) == nil
    end

    test "nil для неактивного ключа" do
      {project, key} = project_fixture()
      {:ok, _} = key |> ProjectKey.changeset(%{active: false}) |> Repo.update()
      assert Projects.get_active_key(project.id, key.public_key) == nil
    end

    test "nil для несуществующего ключа" do
      {project, _key} = project_fixture()
      assert Projects.get_active_key(project.id, String.duplicate("0", 32)) == nil
    end
  end

  describe "ProjectKey.dsn/2" do
    test "собирает DSN в формате Sentry" do
      {project, key} = project_fixture()

      assert ProjectKey.dsn(key, "http://localhost:4000") ==
               "http://#{key.public_key}@localhost:4000/#{project.id}"
    end

    test "опускает стандартный порт" do
      {project, key} = project_fixture()

      assert ProjectKey.dsn(key, "https://swatter.example.com") ==
               "https://#{key.public_key}@swatter.example.com/#{project.id}"
    end
  end
end
