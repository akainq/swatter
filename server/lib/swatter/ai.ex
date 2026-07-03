defmodule Swatter.AI do
  @moduledoc """
  AI-анализ issues на z.ai GLM (ADR-0016). Запускается **только по запросу**
  (поправка 2026-07-03: авто-запуск отключён — контроль расхода токенов):
  `request_analysis/1` ставит фоновую Oban-джобу, результат хранится в
  `issue_ai_analyses` (одна строка на issue, upsert).

  Фича опциональна: без `ZAI_API_KEY` (`enabled?/0`) запрос отклоняется,
  остальной продукт не затронут.
  """

  alias Swatter.AI.{Analysis, AnalyzeIssueWorker}
  alias Swatter.Issues.Issue
  alias Swatter.Repo

  @doc "Настроен ли AI (есть ключ z.ai)."
  def enabled? do
    key = Application.get_env(:swatter, :ai, [])[:api_key]
    is_binary(key) and key != ""
  end

  @doc "Анализ issue (или nil, если не запрашивался)."
  def get_analysis(issue_id), do: Repo.get_by(Analysis, issue_id: issue_id)

  @doc """
  Запросить анализ issue: строка со статусом `pending` + Oban-джоба
  (уникальность 60 с — дубли от повторных кликов схлопываются).
  Без ключа — `{:error, :ai_disabled}`.
  """
  def request_analysis(%Issue{id: issue_id}), do: request_analysis(issue_id)

  def request_analysis(issue_id) when is_integer(issue_id) do
    if enabled?() do
      {:ok, analysis} = upsert(issue_id, %{status: "pending", error: nil})
      {:ok, _job} = %{issue_id: issue_id} |> AnalyzeIssueWorker.new() |> Oban.insert()
      {:ok, analysis}
    else
      {:error, :ai_disabled}
    end
  end

  @doc "Сохранить успешный результат (вызывается воркером)."
  def store_ok(issue_id, fields, model) do
    upsert(
      issue_id,
      Map.merge(fields, %{
        status: "ok",
        model: model,
        error: nil,
        analyzed_at: DateTime.utc_now(:second)
      })
    )
  end

  @doc "Сохранить ошибку анализа (вызывается воркером)."
  def store_error(issue_id, reason) do
    upsert(issue_id, %{
      status: "error",
      error: reason |> to_string() |> String.slice(0, 500),
      analyzed_at: DateTime.utc_now(:second)
    })
  end

  @doc """
  Разбор ответа модели: строгий JSON с ключами summary / probable_cause /
  severity / suggested_fix. Терпим markdown-обёртку ```json; невалидный
  ответ → `{:error, :invalid_response}` (пишется в `status: error`).
  """
  def parse_result(content) when is_binary(content) do
    content
    |> strip_fences()
    |> Jason.decode()
    |> case do
      {:ok, %{"summary" => summary} = map} when is_binary(summary) and summary != "" ->
        {:ok,
         %{
           summary: summary,
           probable_cause: str(map["probable_cause"]),
           severity: normalize_severity(map["severity"]),
           suggested_fix: str(map["suggested_fix"])
         }}

      _ ->
        {:error, :invalid_response}
    end
  end

  defp strip_fences(content) do
    content
    |> String.trim()
    |> String.replace(~r/\A```(?:json)?\s*/, "")
    |> String.replace(~r/```\z/, "")
    |> String.trim()
  end

  defp normalize_severity(severity) when is_binary(severity) do
    severity = String.downcase(severity)
    if severity in Analysis.severities(), do: severity, else: "medium"
  end

  defp normalize_severity(_), do: "medium"

  defp str(value) when is_binary(value), do: value
  defp str(_), do: nil

  defp upsert(issue_id, attrs) do
    (Repo.get_by(Analysis, issue_id: issue_id) || %Analysis{issue_id: issue_id})
    |> Ecto.Changeset.change(attrs)
    |> Repo.insert_or_update()
  end
end
