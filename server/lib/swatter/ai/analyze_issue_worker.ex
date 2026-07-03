defmodule Swatter.AI.AnalyzeIssueWorker do
  @moduledoc """
  Oban-воркер AI-анализа issue (ADR-0016). Очередь `ai` (узкая
  конкуррентность — бережём rate limit z.ai). Берёт issue + последнее
  событие из ClickHouse, строит промпт, зовёт z.ai, пишет результат.

  4xx (плохой ключ, невалидный запрос) — `{:cancel}`: ретрай не поможет.
  Сеть/5xx — ретрай Oban. Невалидный JSON от модели — ретрай (модель
  недетерминирована), после исчерпания попыток остаётся `status: error`.
  """

  use Oban.Worker, queue: :ai, max_attempts: 3, unique: [period: 60, keys: [:issue_id]]

  alias Swatter.{AI, Events, Issues}
  alias Swatter.AI.{Prompt, ZAI}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"issue_id" => issue_id}}) do
    issue = Issues.get_issue(issue_id)

    cond do
      is_nil(issue) -> :ok
      not AI.enabled?() -> :ok
      true -> analyze(issue)
    end
  end

  defp analyze(issue) do
    event = Events.latest_event(issue.id)
    messages = Prompt.build(issue, event)

    with {:ok, content} <- ZAI.chat(messages),
         {:ok, fields} <- AI.parse_result(content) do
      {:ok, _} = AI.store_ok(issue.id, fields, ZAI.model())
      :ok
    else
      {:error, {:http, status, _body} = reason} when status in 400..499 ->
        AI.store_error(issue.id, "z.ai HTTP #{status}")
        {:cancel, inspect(reason)}

      {:error, reason} ->
        AI.store_error(issue.id, inspect(reason))
        {:error, reason}
    end
  end
end
