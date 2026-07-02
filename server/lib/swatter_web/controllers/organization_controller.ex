defmodule SwatterWeb.OrganizationController do
  use SwatterWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Swatter.Accounts
  alias SwatterWeb.{ApiSchemas, Serializer}

  tags(["organizations"])

  operation(:index,
    summary: "Организации текущего пользователя",
    responses: [
      ok:
        {"Организации", "application/json",
         %OpenApiSpex.Schema{type: :array, items: ApiSchemas.Organization}}
    ]
  )

  def index(conn, _params) do
    orgs = Accounts.list_organizations_for(conn.assigns.current_user)
    json(conn, Enum.map(orgs, &Serializer.organization/1))
  end
end
