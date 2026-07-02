defmodule Swatter.Alerts do
  @moduledoc """
  Настройки и правила алертов (ADR-0013). Настройки — per-project
  (`project_alert_settings`); отсутствие строки означает дефолты
  (`%Settings{}`), чтобы не требовать записи при создании проекта.

  Канал один — Telegram: общий bot-token на инстанс (`TELEGRAM_BOT_TOKEN`),
  маршрутизация по per-project `chat_id`. Нет токена или `chat_id` →
  алерты проекта выключены (fail-safe).

  `on_event/1` вызывается пайплайном на каждое событие: правила new/regression
  (по `event_kind`) и порог частоты (счётчик в Redis). Настройки берутся из
  ETS-кэша (`SettingsCache`) — без PG-чтения на горячем пути.
  """

  alias Swatter.Alerts.{NotifyWorker, Settings, SettingsCache}
  alias Swatter.Ingest.Buffer
  alias Swatter.Issues.Issue
  alias Swatter.Repo

  @doc "Настройки проекта: сохранённые или дефолтная (не персистентная) структура."
  def get_settings(project_id) do
    Repo.get_by(Settings, project_id: project_id) || %Settings{project_id: project_id}
  end

  @doc "Создать/обновить настройки проекта (upsert по `project_id`); сбрасывает кэш."
  def upsert_settings(project_id, attrs) do
    result =
      (Repo.get_by(Settings, project_id: project_id) || %Settings{project_id: project_id})
      |> Settings.changeset(attrs)
      |> Repo.insert_or_update()

    with {:ok, _} <- result, do: SettingsCache.invalidate(project_id)
    result
  end

  @doc """
  Вызывается пайплайном на каждое персистнутое событие. По кэшированным
  настройкам проверяет правила new/regression и порог частоты, ставит
  Oban-джобы доставки. Тяжёлого — ничего: ETS-чтение + (при настроенном
  правиле) Redis + быстрый `Oban.insert`.
  """
  def on_event(%Issue{} = issue) do
    settings = SettingsCache.get(issue.project_id)
    notify_event_kind(issue, settings)
    notify_frequency(issue, settings)
    :ok
  end

  @doc "Только правила new/regression по `event_kind` (подмножество `on_event/1`)."
  def maybe_notify(%Issue{} = issue) do
    notify_event_kind(issue, SettingsCache.get(issue.project_id))
    :ok
  end

  defp notify_event_kind(%Issue{event_kind: kind} = issue, settings)
       when kind in ["new", "regression"] do
    rule = if kind == "new", do: "new_issue", else: "regression"

    enabled? =
      (kind == "new" and settings.on_new_issue) or
        (kind == "regression" and settings.on_regression)

    if enabled? and telegram_ready?(settings) and acquire_cooldown(issue.id, rule) do
      enqueue(issue.id, rule)
    end

    :ok
  end

  defp notify_event_kind(_issue, _settings), do: :ok

  # порог частоты: N событий по issue за окно T. Fixed window в Redis; алерт
  # ровно на пороговом событии (`== threshold`, INCR атомарен), cooldown —
  # чтобы после сброса окна не спамило.
  defp notify_frequency(%Issue{} = issue, %Settings{frequency_threshold: threshold} = settings)
       when is_integer(threshold) and threshold > 0 do
    window = settings.frequency_window_seconds || 300

    if telegram_ready?(settings) and incr_frequency(issue.id, window) == threshold and
         acquire_cooldown(issue.id, "frequency") do
      enqueue(issue.id, "frequency")
    end

    :ok
  end

  defp notify_frequency(_issue, _settings), do: :ok

  @doc """
  Готов ли Telegram-канал: есть общий bot-token, у проекта включены алерты и
  задан `chat_id`. Без этого доставка невозможна.
  """
  def telegram_ready?(%Settings{enabled: true, telegram_chat_id: chat_id})
      when is_binary(chat_id) and chat_id != "" do
    token = bot_token()
    is_binary(token) and token != ""
  end

  def telegram_ready?(_), do: false

  @doc "Общий bot-token инстанса (ADR-0013) или nil."
  def bot_token, do: alerts_config()[:telegram_bot_token]

  defp enqueue(issue_id, rule) do
    %{issue_id: issue_id, rule: rule} |> NotifyWorker.new() |> Oban.insert()
  end

  # частотный счётчик: fixed window в Redis (INCR + EXPIRE), паттерн ADR-0009.
  # Ошибка Redis → 0 (частотный алерт не сработает — приемлемо).
  defp incr_frequency(issue_id, window) do
    bucket = div(System.system_time(:second), window) * window
    key = "swatter:alert:freq:#{issue_id}:#{bucket}"

    case Redix.pipeline(Buffer.conn_name(), [
           ["INCR", key],
           ["EXPIRE", key, Integer.to_string(window + 1)]
         ]) do
      {:ok, [count, _]} when is_integer(count) -> count
      _ -> 0
    end
  end

  # cooldown per-(issue, rule): SET NX EX. fail-open при недоступном Redis —
  # лучше продублировать алерт, чем потерять.
  defp acquire_cooldown(issue_id, rule) do
    key = "swatter:alert:cd:#{issue_id}:#{rule}"

    case Redix.command(Buffer.conn_name(), ["SET", key, "1", "NX", "EX", cooldown_seconds()]) do
      {:ok, "OK"} -> true
      {:ok, nil} -> false
      {:error, _} -> true
    end
  end

  defp cooldown_seconds, do: alerts_config()[:cooldown_seconds] || 900

  defp alerts_config, do: Application.get_env(:swatter, :alerts, [])
end
