defmodule Swatter.Pipeline do
  @moduledoc """
  Broadway-пайплайн (ADR-0002/0005): consumer group поверх Redis Stream →
  разбор envelope → нормализация → fingerprint → upsert issue (PG) →
  батч-вставка событий в ClickHouse.

  Ошибки двух сортов:
  - «ядовитый» контент (битый envelope/JSON) — событие отбрасывается с
    логом, сообщение ack'ается (retry не поможет);
  - инфраструктурные (PG/CH недоступны) — исключение валит сообщение,
    `handle_failed/2` просит redelivery до 5 попыток.
  """

  use Broadway

  require Logger

  alias Broadway.Message
  alias Swatter.Events.Event
  alias Swatter.EventsRepo
  alias Swatter.Ingest.Envelope
  alias Swatter.Issues
  alias Swatter.Pipeline.Normalizer
  alias Swatter.Projects

  @max_attempts 5

  def start_link(opts) do
    cfg = Application.fetch_env!(:swatter, :pipeline)
    ingest = Application.fetch_env!(:swatter, :ingest)
    redis_opts = Swatter.Redis.opts_from_url(Application.fetch_env!(:swatter, :redis_url))

    Broadway.start_link(__MODULE__,
      name: Keyword.get(opts, :name, __MODULE__),
      # group_start_id "0": группа создаётся с начала стрима — backlog,
      # накопленный до первого старта пайплайна, не теряется
      producer: [
        module:
          {OffBroadwayRedisStream.Producer,
           redis_client_opts: redis_opts,
           stream: ingest[:stream],
           group: cfg[:group],
           consumer_name: consumer_name(),
           group_start_id: "0",
           make_stream: true},
        concurrency: 1
      ],
      processors: [
        default: [concurrency: cfg[:processor_concurrency]]
      ],
      batchers: [
        clickhouse: [
          concurrency: 1,
          batch_size: cfg[:batch_size],
          batch_timeout: cfg[:batch_timeout]
        ],
        # сообщения без событий (session-only envelope, отброшенный мусор)
        noop: [concurrency: 1, batch_size: 100, batch_timeout: 1_000]
      ]
    )
  end

  @impl true
  def handle_message(_processor, %Message{data: [redis_id, fields]} = message, _context)
      when is_binary(redis_id) and is_list(fields) do
    entry = fields |> Enum.chunk_every(2) |> Map.new(fn [k, v] -> {k, v} end)

    case process_entry(entry) do
      {:ok, [_ | _] = rows} ->
        message |> Message.put_data(rows) |> Message.put_batcher(:clickhouse)

      _empty_or_dropped ->
        message |> Message.put_data([]) |> Message.put_batcher(:noop)
    end
  end

  # Redelivery после сбоя батчера: producer переигрывает сообщение с уже
  # построенными строками — issue не апсертим повторно, только довставляем в CH
  def handle_message(_processor, %Message{data: rows} = message, _context) when is_list(rows) do
    case rows do
      [_ | _] -> Message.put_batcher(message, :clickhouse)
      [] -> Message.put_batcher(message, :noop)
    end
  end

  defp process_entry(entry) do
    with {project_id, ""} <- Integer.parse(entry["project_id"] || ""),
         %{} = project <- Projects.get_project(project_id),
         {:ok, _header, items} <- Envelope.parse(entry["payload"]) do
      received_at =
        entry["received_at"]
        |> String.to_integer()
        |> DateTime.from_unix!(:millisecond)

      rows =
        items
        |> Enum.filter(fn {item_header, _} -> item_header["type"] == "event" end)
        |> Enum.flat_map(&persist_event(&1, project, received_at))

      {:ok, rows}
    else
      nil ->
        Logger.warning("pipeline: dropping envelope for unknown project #{entry["project_id"]}")
        :drop

      _ ->
        Logger.warning("pipeline: dropping malformed envelope (project #{entry["project_id"]})")
        :drop
    end
  end

  defp persist_event({_item_header, payload}, project, received_at) do
    case Jason.decode(payload) do
      {:ok, event} when is_map(event) ->
        # JS-символикация ДО нормализации (ADR-0011): fingerprint считается
        # по развёрнутому стеку. Best-effort — без карты событие не теряется
        event = Swatter.Symbolication.symbolicate(event, project.id)
        normalized = Normalizer.normalize(event, received_at)

        # релиз события (ADR-0011): создаётся при первом появлении,
        # даёт порядок для regression-детекта. received_at берём
        # нормализованный (usec-точность для :utc_datetime_usec)
        release =
          Swatter.Releases.get_or_create(project.id, normalized.release, normalized.received_at)

        # инфраструктурная ошибка PG уронит сообщение → redelivery
        {:ok, issue} =
          Issues.upsert_from_event(normalized, project.organization_id, project.id, release)

        # алерты (ADR-0013): правила new/regression + порог частоты; ставит
        # быстрый Oban.insert, тяжёлый HTTP уходит в воркер (инвариант приёма)
        Swatter.Alerts.on_event(issue)

        [build_row(normalized, issue, project)]

      _ ->
        Logger.warning("pipeline: dropping malformed event item (project #{project.id})")
        []
    end
  end

  defp build_row(normalized, issue, project) do
    # title/fingerprint/grouping_version — атрибуты issue, не события
    normalized
    |> Map.drop([:fingerprint_hash, :grouping_version, :title])
    |> Map.merge(%{
      org_id: project.organization_id,
      project_id: project.id,
      issue_id: issue.id
    })
  end

  @impl true
  def handle_batch(:clickhouse, messages, _batch_info, _context) do
    rows = Enum.flat_map(messages, & &1.data)

    # инфраструктурная ошибка CH валит весь батч → redelivery всех сообщений
    EventsRepo.insert_all(Event, rows)
    messages
  end

  def handle_batch(:noop, messages, _batch_info, _context) do
    messages
  end

  @impl true
  def handle_failed(messages, _context) do
    Enum.map(messages, fn message ->
      attempt = message.metadata[:attempt] || 1

      if attempt < @max_attempts do
        Logger.warning("pipeline: retrying message, attempt #{attempt}/#{@max_attempts}")
        Message.configure_ack(message, retry: true)
      else
        Logger.error(
          "pipeline: dropping message after #{attempt} attempts: #{inspect(message.status)}"
        )

        message
      end
    end)
  end

  defp consumer_name do
    # стабильное имя на ноду: после рестарта consumer забирает свои
    # pending-сообщения обратно
    "swatter-#{node()}"
  end
end
