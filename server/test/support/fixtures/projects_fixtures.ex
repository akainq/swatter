defmodule Swatter.ProjectsFixtures do
  @moduledoc false

  alias Swatter.Projects

  def org_fixture(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, org} =
      attrs
      |> Enum.into(%{name: "Org #{n}", slug: "org-#{n}"})
      |> Projects.create_organization()

    org
  end

  @doc "Возвращает {project, key}."
  def project_fixture(org \\ nil, attrs \\ %{}) do
    org = org || org_fixture()
    n = System.unique_integer([:positive])

    {:ok, project, key} =
      Projects.create_project(org, Enum.into(attrs, %{name: "Project #{n}", slug: "proj-#{n}"}))

    {project, key}
  end
end
