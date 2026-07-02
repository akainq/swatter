# Dev-сиды: организация + проект + DSN-ключ (идемпотентно).
# Запуск: mix run priv/repo/seeds.exs

alias Swatter.Projects

org =
  case Projects.get_organization_by_slug("swatter") do
    nil ->
      {:ok, org} = Projects.create_organization(%{name: "Swatter", slug: "swatter"})
      org

    org ->
      org
  end

project =
  case Projects.get_project_by_slug(org, "playground") do
    nil ->
      {:ok, project, _key} =
        Projects.create_project(org, %{name: "Playground", slug: "playground"})

      project

    project ->
      project
  end

key = Projects.first_key(project)

# Dev-пользователь (owner). Только для локальной разработки.
alias Swatter.Accounts

dev_email = "admin@swatter.local"
dev_password = "swatter-dev-password"

user =
  case Accounts.get_user_by_email(dev_email) do
    nil ->
      {:ok, user} =
        Accounts.register_user(%{
          "email" => dev_email,
          "name" => "Dev Admin",
          "password" => dev_password
        })

      user

    user ->
      user
  end

unless Accounts.member?(user, org.id) do
  {:ok, _} = Accounts.add_member(user, org, "owner")
end

IO.puts("""

  org:     #{org.slug}
  project: #{project.slug} (id=#{project.id})
  DSN:     http://#{key.public_key}@127.0.0.1:4000/#{project.id}
  login:   #{dev_email} / #{dev_password}
""")
