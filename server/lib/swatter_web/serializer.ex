defmodule SwatterWeb.Serializer do
  @moduledoc """
  Сборка JSON-ответов dashboard API. Имена полей — camelCase в стиле
  Sentry (ADR-0008: узнаваемость формы, совместимость не обещаем).
  """

  alias Swatter.Projects.ProjectKey

  def organization(org) do
    %{"id" => to_string(org.id), "slug" => org.slug, "name" => org.name}
  end

  def current_user(user, memberships) do
    %{
      "id" => to_string(user.id),
      "email" => user.email,
      "name" => user.name,
      "memberships" =>
        Enum.map(memberships, fn m ->
          %{"role" => m.role, "organization" => organization(m.organization)}
        end)
    }
  end

  def project(project, base_url) do
    key = project.keys |> Enum.filter(& &1.active) |> List.first()

    %{
      "id" => to_string(project.id),
      "slug" => project.slug,
      "name" => project.name,
      "platform" => project.platform,
      "dsn" => if(key, do: ProjectKey.dsn(key, base_url))
    }
  end

  def project_with_stats(
        %{project: project, unresolved_issues: unresolved, events_24h: events},
        base_url
      ) do
    project
    |> project(base_url)
    |> Map.merge(%{"unresolvedIssues" => unresolved, "events24h" => events})
  end

  def issue(issue, project \\ nil) do
    project = project || preloaded_project(issue)

    %{
      "id" => to_string(issue.id),
      "title" => issue.title,
      "culprit" => issue.culprit,
      "level" => issue.level,
      "status" => issue.status,
      "count" => issue.times_seen,
      "regressed" => issue.regressed,
      "firstSeen" => DateTime.to_iso8601(issue.first_seen),
      "lastSeen" => DateTime.to_iso8601(issue.last_seen),
      "project" => if(project, do: %{"id" => to_string(project.id), "slug" => project.slug})
    }
  end

  def release(%{release: release, new_issues: new_issues}) do
    release |> release() |> Map.put("newIssues", new_issues)
  end

  def release(release) do
    %{
      "id" => to_string(release.id),
      "version" => release.version,
      "ordinal" => release.ordinal,
      "firstEventAt" => release.first_event_at && DateTime.to_iso8601(release.first_event_at)
    }
  end

  def event(row) do
    payload = Jason.decode!(row.payload)

    %{
      "eventId" => row.event_id,
      "timestamp" => DateTime.to_iso8601(row.timestamp),
      "dateReceived" => DateTime.to_iso8601(row.received_at),
      "level" => row.level,
      "message" => row.message,
      "platform" => row.platform,
      "release" => row.release,
      "environment" => row.environment,
      "traceId" => row.trace_id,
      "sdk" => %{"name" => row.sdk_name, "version" => row.sdk_version},
      "user" => %{
        "id" => row.user_id,
        "email" => row.user_email,
        "ipAddress" => row.user_ip
      },
      "tags" => Enum.map(row.tags, fn {k, v} -> %{"key" => k, "value" => v} end),
      "exception" => payload["exception"],
      "breadcrumbs" => payload["breadcrumbs"],
      "contexts" => payload["contexts"]
    }
  end

  defp preloaded_project(issue) do
    case issue.project do
      %Ecto.Association.NotLoaded{} -> nil
      project -> project
    end
  end

  @doc "Ошибки changeset одной строкой для поля detail."
  def changeset_detail(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.map_join("; ", fn {field, errors} -> "#{field}: #{Enum.join(errors, ", ")}" end)
  end
end
