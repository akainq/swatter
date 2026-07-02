defmodule Swatter.Alerts.Message do
  @moduledoc """
  Форматирование текста Telegram-алерта (ADR-0013). Plain text. Ожидает issue
  с преднагруженными `project` и `project.organization` (см. `Issues.get_issue/1`).
  """

  alias Swatter.Issues.Issue

  @headers %{
    "new_issue" => "🔴 Новый issue",
    "regression" => "🔁 Регрессия",
    "frequency" => "📈 Всплеск частоты"
  }

  @doc """
  Собирает текст сообщения. `opts[:ai_summary]` — краткое AI-резюме (ADR-0016),
  вставляется строкой, если передано.
  """
  def build(%Issue{} = issue, rule, opts \\ []) do
    header = Map.get(@headers, rule, "⚠️ Алерт")
    project = issue.project

    [
      "#{header} · #{project_name(project)}",
      issue.title,
      cline("at ", issue.culprit),
      "level: #{issue.level} · seen ×#{issue.times_seen}",
      cline("🤖 ", opts[:ai_summary]),
      issue_url(issue)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  defp cline(_prefix, nil), do: nil
  defp cline(_prefix, ""), do: nil
  defp cline(prefix, value), do: prefix <> value

  defp project_name(nil), do: "project"
  defp project_name(project), do: project.name || project.slug

  defp issue_url(%Issue{project: %{organization: %{} = org} = project} = issue) do
    "#{SwatterWeb.Endpoint.url()}/#{org.slug}/#{project.slug}/issues/#{issue.id}"
  end

  defp issue_url(_issue), do: nil
end
