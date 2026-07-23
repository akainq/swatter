defmodule Swatter.MCP.Tools do
  @moduledoc """
  Тулы MCP-сервера (ADR-0017). Ответы — компактный markdown под LLM.
  Видимость данных = организации пользователя-владельца токена (те же
  `member?`-проверки, что в dashboard API); чужое неотличимо от
  несуществующего.
  """

  alias Swatter.{Accounts, Events, Issues, Projects, Spans}
  alias Swatter.Accounts.User

  @doc "Описания тулов для `tools/list` (JSON Schema входа)."
  def list do
    [
      %{
        name: "get_issue",
        description:
          "Get full details of a Swatter issue for debugging: symbolicated stack trace " <>
            "with source context, tags, breadcrumbs, AI analysis (if run), and related " <>
            "errors from the same trace. Accepts an issue URL from the Swatter UI or a " <>
            "numeric issue id.",
        inputSchema: %{
          type: "object",
          properties: %{
            issue: %{
              type: "string",
              description: "Issue URL (https://host/org/project/issues/123) or numeric id"
            }
          },
          required: ["issue"]
        }
      },
      %{
        name: "list_issues",
        description:
          "Search issues of a project when you don't have a direct link. " <>
            "Returns ids usable with get_issue.",
        inputSchema: %{
          type: "object",
          properties: %{
            project: %{type: "string", description: "Project slug"},
            organization: %{
              type: "string",
              description: "Organization slug (optional if the token sees only one)"
            },
            query: %{type: "string", description: "Substring of title or culprit"},
            status: %{
              type: "string",
              enum: ["unresolved", "resolved", "ignored", "all"],
              description: "Default: unresolved"
            },
            limit: %{type: "integer", description: "Max results, default 20, cap 50"}
          },
          required: ["project"]
        }
      },
      %{
        name: "get_trace",
        description:
          "Get the span tree of a trace (cross-service waterfall) plus errors that " <>
            "happened in it. Accepts a trace URL or a 32-hex trace id.",
        inputSchema: %{
          type: "object",
          properties: %{
            trace: %{type: "string", description: "Trace URL or 32-hex trace id"},
            organization: %{
              type: "string",
              description: "Organization slug (optional if the token sees only one)"
            }
          },
          required: ["trace"]
        }
      },
      %{
        name: "resolve_issue",
        description:
          "Mark a Swatter issue as resolved after the fix. Accepts an issue URL or id.",
        inputSchema: %{
          type: "object",
          properties: %{
            issue: %{type: "string", description: "Issue URL or numeric id"}
          },
          required: ["issue"]
        }
      }
    ]
  end

  @doc "Исполнение тула: {:ok, text} | {:error, text} (isError для клиента)."
  def call("get_issue", args, %User{} = user) do
    with {:ok, issue} <- fetch_issue(user, args["issue"]) do
      {:ok, format_issue(issue)}
    end
  end

  def call("list_issues", args, %User{} = user) do
    with {:ok, org} <- resolve_org(user, args["organization"]),
         {:ok, project} <- resolve_project(org, args["project"]) do
      opts = [
        status: args["status"] || "unresolved",
        query: args["query"],
        limit: args |> int_arg("limit", 20) |> min(50) |> max(1)
      ]

      case Issues.list_issues(project.id, opts) do
        {:ok, [], _cursor} ->
          {:ok, "No issues matched in #{org.slug}/#{project.slug}."}

        {:ok, issues, _cursor} ->
          lines =
            Enum.map(issues, fn issue ->
              "- ##{issue.id} [#{issue.level}/#{issue.status}] #{issue.title} — " <>
                "#{issue.culprit} (events: #{issue.times_seen}, last seen #{DateTime.to_iso8601(issue.last_seen)})"
            end)

          {:ok,
           "Issues in #{org.slug}/#{project.slug} (use get_issue with an id):\n" <>
             Enum.join(lines, "\n")}

        {:error, _} ->
          {:error, "Could not list issues."}
      end
    end
  end

  def call("get_trace", args, %User{} = user) do
    with {:ok, trace_id} <- parse_trace_ref(args["trace"]),
         {:ok, org, spans} <- find_trace(user, args["organization"], trace_id) do
      {:ok, format_trace(org, trace_id, spans)}
    end
  end

  def call("resolve_issue", args, %User{} = user) do
    with {:ok, issue} <- fetch_issue(user, args["issue"]),
         {:ok, _updated} <- Issues.update_status(issue, "resolved") do
      {:ok, "Issue ##{issue.id} marked as resolved.\nWeb: #{issue_url(issue)}"}
    else
      {:error, message} when is_binary(message) -> {:error, message}
      _ -> {:error, "Could not resolve the issue."}
    end
  end

  def call(_unknown, _args, _user), do: {:error, "Unknown tool."}

  ## get_issue: сборка markdown

  defp format_issue(issue) do
    event = Events.latest_event(issue.id)
    payload = decode_payload(event)
    analysis = Swatter.AI.get_analysis(issue.id)

    [
      header_block(issue),
      stack_block(payload, event),
      tags_block(event),
      breadcrumbs_block(payload),
      ai_block(analysis),
      related_block(issue, event),
      "Web: #{issue_url(issue)}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp header_block(issue) do
    project = issue.project

    """
    # Issue ##{issue.id}: #{issue.title}
    Project: #{project.organization.slug}/#{project.slug} · Status: #{issue.status}#{if issue.regressed, do: " (regression)", else: ""} · Level: #{issue.level}
    Events: #{issue.times_seen} · First seen: #{DateTime.to_iso8601(issue.first_seen)} · Last seen: #{DateTime.to_iso8601(issue.last_seen)}
    Culprit: #{issue.culprit}
    """
    |> String.trim_trailing()
  end

  defp stack_block(%{} = payload, event) when map_size(payload) > 0 do
    values =
      case payload["exception"] do
        %{"values" => values} when is_list(values) -> values
        values when is_list(values) -> values
        _ -> []
      end

    case List.last(values) do
      %{"stacktrace" => %{"frames" => frames}} = exception when is_list(frames) ->
        # верхний кадр первым; * = развёрнут из sourcemap
        lines =
          frames
          |> Enum.reverse()
          |> Enum.map(fn frame ->
            marker = if get_in(frame, ["data", "symbolicated"]) == true, do: " *", else: ""
            location = "#{frame["filename"] || frame["module"] || "?"}:#{frame["lineno"] || "?"}"
            base = "  at #{frame["function"] || "?"} (#{location})#{marker}"

            case frame["context_line"] do
              context when is_binary(context) and context != "" ->
                base <> "\n      > " <> String.trim(context)

              _ ->
                base
            end
          end)

        "## Stack trace (latest event #{event && event.event_id}, top frame first, * = source-mapped)\n" <>
          "#{exception["type"]}: #{exception["value"]}\n" <> Enum.join(lines, "\n")

      _ ->
        nil
    end
  end

  defp stack_block(_payload, _event), do: nil

  defp tags_block(%{tags: tags} = event) when map_size(tags) > 0 do
    pairs = Enum.map_join(tags, " · ", fn {k, v} -> "#{k}=#{v}" end)

    "## Tags\n#{pairs}\nEnvironment: #{event.environment} · Release: #{event.release} · Platform: #{event.platform}"
  end

  defp tags_block(%{} = event),
    do: "## Tags\nEnvironment: #{event.environment} · Release: #{event.release}"

  defp tags_block(_), do: nil

  defp breadcrumbs_block(payload) do
    crumbs =
      case payload["breadcrumbs"] do
        %{"values" => values} when is_list(values) -> values
        values when is_list(values) -> values
        _ -> []
      end

    case Enum.take(crumbs, -10) do
      [] ->
        nil

      crumbs ->
        "## Breadcrumbs (last #{length(crumbs)})\n" <>
          Enum.map_join(crumbs, "\n", fn crumb ->
            "- [#{crumb["category"] || crumb["type"] || "?"}] #{crumb["message"] || ""}"
          end)
    end
  end

  defp ai_block(%{status: "ok"} = analysis) do
    """
    ## AI analysis (#{analysis.model})
    Severity: #{analysis.severity}
    Summary: #{analysis.summary}
    Probable cause: #{analysis.probable_cause}
    Suggested fix: #{analysis.suggested_fix}
    """
    |> String.trim_trailing()
  end

  defp ai_block(_), do: nil

  defp related_block(issue, %{trace_id: trace_id}) when is_binary(trace_id) and trace_id != "" do
    related =
      issue.project.organization_id
      |> Events.related_by_trace(trace_id)
      |> Enum.reject(&(&1.issue_id == issue.id))

    lines =
      Enum.map(related, fn row ->
        title =
          if row.exception_type == "",
            do: row.message,
            else: "#{row.exception_type}: #{row.exception_value}"

        "- issue ##{row.issue_id} [#{row.level}] #{title}"
      end)

    base = "## Trace\nTrace id: #{trace_id} (use get_trace for the cross-service waterfall)"

    case lines do
      [] ->
        base

      lines ->
        base <> "\nRelated errors in this trace (other issues):\n" <> Enum.join(lines, "\n")
    end
  end

  defp related_block(_issue, _event), do: nil

  ## get_trace: сборка дерева

  defp format_trace(org, trace_id, spans) do
    errors = Events.related_by_trace(org.id, trace_id)
    slugs = org |> Projects.list_projects() |> Map.new(&{&1.id, &1.slug})
    multi? = spans |> Enum.map(& &1.project_id) |> Enum.uniq() |> length() > 1

    {min_start, max_end} =
      Enum.reduce(spans, {nil, nil}, fn span, {min_acc, max_acc} ->
        {min_dt(min_acc, span.start_ts), max_dt(max_acc, span.end_ts)}
      end)

    total_ms =
      if min_start && max_end,
        do: max(DateTime.diff(max_end, min_start, :microsecond) / 1000, 1.0),
        else: 1.0

    tree =
      spans
      |> span_nodes()
      |> Enum.map_join("\n", fn {span, depth} ->
        indent = String.duplicate("  ", depth)
        marker = if span.is_segment == 1, do: "* ", else: "- "
        project = if multi?, do: " [#{Map.get(slugs, span.project_id, "?")}]", else: ""
        desc = if span.description == "", do: span.transaction_name, else: span.description

        "#{indent}#{marker}#{span.op} #{desc}#{project} — #{Float.round(span.duration_ms * 1.0, 1)} ms"
      end)

    error_lines =
      Enum.map(errors, fn row ->
        title =
          if row.exception_type == "",
            do: row.message,
            else: "#{row.exception_type}: #{row.exception_value}"

        slug = Map.get(slugs, row.project_id, "?")
        "- issue ##{row.issue_id} [#{slug}] #{title} (#{row.level})"
      end)

    [
      "# Trace #{trace_id}",
      "#{length(spans)} spans · #{Float.round(total_ms, 1)} ms total · organization #{org.slug}",
      "Spans (top first, * = transaction segment):\n#{tree}",
      case error_lines do
        [] -> "No errors recorded in this trace."
        lines -> "Errors in this trace (use get_issue):\n" <> Enum.join(lines, "\n")
      end
    ]
    |> Enum.join("\n\n")
  end

  # дерево по parent_span_id → плоский DFS с глубиной; сироты — корни
  defp span_nodes(spans) do
    ids = MapSet.new(spans, & &1.span_id)

    children =
      Enum.group_by(spans, fn span ->
        if span.parent_span_id != "" and MapSet.member?(ids, span.parent_span_id),
          do: span.parent_span_id,
          else: :root
      end)

    walk = fn walk, span, depth ->
      kids = children |> Map.get(span.span_id, []) |> Enum.sort_by(& &1.start_ts, DateTime)
      [{span, depth} | Enum.flat_map(kids, &walk.(walk, &1, depth + 1))]
    end

    children
    |> Map.get(:root, [])
    |> Enum.sort_by(& &1.start_ts, DateTime)
    |> Enum.flat_map(&walk.(walk, &1, 0))
  end

  ## Разбор ссылок и авторизация

  defp fetch_issue(user, ref) do
    with {:ok, issue_id} <- parse_issue_ref(ref),
         %{} = issue <- Issues.get_issue(issue_id),
         true <- Accounts.member?(user, issue.project.organization_id) do
      {:ok, issue}
    else
      :error -> {:error, "Pass an issue URL from the Swatter UI or a numeric issue id."}
      _ -> {:error, "Issue not found."}
    end
  end

  defp parse_issue_ref(ref) when is_binary(ref) do
    trimmed = String.trim(ref)

    cond do
      match = Regex.run(~r{/issues/(\d+)}, trimmed) ->
        {:ok, match |> Enum.at(1) |> String.to_integer()}

      Regex.match?(~r/^#?\d+$/, trimmed) ->
        {:ok, trimmed |> String.trim_leading("#") |> String.to_integer()}

      true ->
        :error
    end
  end

  defp parse_issue_ref(ref) when is_integer(ref), do: {:ok, ref}
  defp parse_issue_ref(_), do: :error

  defp parse_trace_ref(ref) when is_binary(ref) do
    candidate =
      case Regex.run(~r{/traces/([0-9a-fA-F-]+)}, ref) do
        [_, id] -> id
        _ -> ref
      end

    normalized = candidate |> String.trim() |> String.replace("-", "") |> String.downcase()

    if normalized =~ ~r/^[0-9a-f]{32}$/ do
      {:ok, normalized}
    else
      {:error, "Pass a trace URL or a 32-hex trace id."}
    end
  end

  defp parse_trace_ref(_), do: {:error, "Pass a trace URL or a 32-hex trace id."}

  defp resolve_org(user, nil), do: only_org(user)

  defp resolve_org(user, slug) do
    with %{} = org <- Projects.get_organization_by_slug(to_string(slug)),
         true <- Accounts.member?(user, org.id) do
      {:ok, org}
    else
      _ -> {:error, "Organization not found."}
    end
  end

  defp only_org(user) do
    case Accounts.list_organizations_for(user) do
      [org] ->
        {:ok, org}

      orgs when orgs != [] ->
        slugs = Enum.map_join(orgs, ", ", & &1.slug)
        {:error, "Multiple organizations available (#{slugs}) — pass `organization`."}

      _ ->
        {:error, "No organizations available for this token."}
    end
  end

  defp resolve_project(_org, nil), do: {:error, "Pass `project` (slug)."}

  defp resolve_project(org, slug) do
    case Projects.get_project_by_slug(org, to_string(slug)) do
      nil ->
        slugs = org |> Projects.list_projects() |> Enum.map_join(", ", & &1.slug)
        {:error, "Project not found. Available in #{org.slug}: #{slugs}."}

      project ->
        {:ok, project}
    end
  end

  # трейс ищем в явно указанной организации либо по всем организациям токена
  defp find_trace(user, org_slug, trace_id) do
    orgs =
      case org_slug do
        nil ->
          Accounts.list_organizations_for(user)

        slug ->
          case resolve_org(user, slug) do
            {:ok, org} -> [org]
            _ -> []
          end
      end

    orgs
    |> Enum.find_value(fn org ->
      case Spans.trace_spans(org.id, trace_id) do
        [] -> nil
        spans -> {:ok, org, spans}
      end
    end)
    |> case do
      nil -> {:error, "Trace not found."}
      found -> found
    end
  end

  ## Утилиты

  defp decode_payload(nil), do: %{}

  defp decode_payload(%{payload: payload}) when is_binary(payload) do
    case Jason.decode(payload) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp decode_payload(_), do: %{}

  defp issue_url(issue) do
    project = issue.project
    "#{SwatterWeb.Endpoint.url()}/#{project.organization.slug}/#{project.slug}/issues/#{issue.id}"
  end

  defp int_arg(args, key, default) do
    case args[key] do
      n when is_integer(n) ->
        n

      n when is_binary(n) ->
        case Integer.parse(n) do
          {value, ""} -> value
          _ -> default
        end

      _ ->
        default
    end
  end

  defp min_dt(nil, dt), do: dt
  defp min_dt(acc, dt), do: if(DateTime.compare(dt, acc) == :lt, do: dt, else: acc)

  defp max_dt(nil, dt), do: dt
  defp max_dt(acc, dt), do: if(DateTime.compare(dt, acc) == :gt, do: dt, else: acc)
end
