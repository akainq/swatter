defmodule Swatter.Alerts.NotifyWorker do
  @moduledoc """
  Oban-воркер доставки алерта в Telegram (ADR-0013). Очередь `alerts`.
  Собирает контекст issue, форматирует сообщение и шлёт через Telegram Bot API.

  Ретраи Oban — на сеть/5xx. 4xx (кривой `chat_id`, бот забанен) отменяют
  джобу (`{:cancel, _}`): повтор не поможет. Пропавший issue или неготовый
  канал — тихий `:ok` (нечего слать).
  """

  use Oban.Worker, queue: :alerts, max_attempts: 5

  alias Swatter.Alerts
  alias Swatter.Alerts.{Message, Telegram}
  alias Swatter.Issues

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"issue_id" => issue_id, "rule" => rule} = args}) do
    issue = Issues.get_issue(issue_id)
    settings = issue && Alerts.get_settings(issue.project_id)

    cond do
      is_nil(issue) ->
        :ok

      not Alerts.telegram_ready?(settings) ->
        :ok

      true ->
        text = Message.build(issue, rule, host: args["host"])
        deliver(settings.telegram_chat_id, text)
    end
  end

  defp deliver(chat_id, text) do
    case Telegram.send_message(chat_id, text) do
      :ok ->
        :ok

      {:error, {:http, status, _body}} when status in 400..499 ->
        {:cancel, "telegram #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
