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

  def transaction_stat(stat) do
    %{
      "transaction" => stat.transaction,
      "count" => stat.count,
      "rpm" => Float.round(stat.rpm, 3),
      "p50" => Float.round(stat.p50 * 1.0, 2),
      "p95" => Float.round(stat.p95 * 1.0, 2),
      "lastSeen" => DateTime.to_iso8601(stat.last_seen)
    }
  end

  def trace_summary(row) do
    %{
      "traceId" => row.trace_id,
      "startTs" => DateTime.to_iso8601(row.start_ts),
      "durationMs" => Float.round(row.duration_ms * 1.0, 2),
      "status" => row.status,
      "environment" => row.environment,
      "release" => row.release
    }
  end

  def trace_span(span, project_slugs) do
    %{
      "spanId" => span.span_id,
      "parentSpanId" => span.parent_span_id,
      "isSegment" => span.is_segment == 1,
      "transaction" => span.transaction_name,
      "op" => span.op,
      "description" => span.description,
      "status" => span.status,
      "startTs" => DateTime.to_iso8601(span.start_ts),
      "endTs" => DateTime.to_iso8601(span.end_ts),
      "durationMs" => Float.round(span.duration_ms * 1.0, 2),
      "projectId" => to_string(span.project_id),
      "projectSlug" => Map.get(project_slugs, span.project_id)
    }
  end

  def related_error(row, project_slugs) do
    title =
      case row.exception_type do
        "" -> row.message
        type -> "#{type}: #{row.exception_value}"
      end

    %{
      "eventId" => row.event_id,
      "issueId" => to_string(row.issue_id),
      "projectId" => to_string(row.project_id),
      "projectSlug" => Map.get(project_slugs, row.project_id),
      "title" => String.slice(title, 0, 200),
      "level" => row.level,
      "timestamp" => DateTime.to_iso8601(row.timestamp)
    }
  end

  def ai_analysis(nil), do: nil

  def ai_analysis(analysis) do
    %{
      "status" => analysis.status,
      "summary" => analysis.summary,
      "probableCause" => analysis.probable_cause,
      "severity" => analysis.severity,
      "suggestedFix" => analysis.suggested_fix,
      "model" => analysis.model,
      "error" => analysis.error,
      "analyzedAt" => analysis.analyzed_at && DateTime.to_iso8601(analysis.analyzed_at)
    }
  end

  def alert_settings(settings, telegram_configured?) do
    %{
      "enabled" => settings.enabled,
      "telegramChatId" => settings.telegram_chat_id,
      "telegramConfigured" => telegram_configured?,
      "onNewIssue" => settings.on_new_issue,
      "onRegression" => settings.on_regression,
      "frequencyThreshold" => settings.frequency_threshold,
      "frequencyWindowSeconds" => settings.frequency_window_seconds
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
