defmodule SwatterWeb.IngestController do
  @moduledoc """
  Приём событий по протоколу Sentry (ADR-0001):

  - `POST /api/{project_id}/envelope/` — основной (envelope);
  - `POST /api/{project_id}/store/` — legacy (голый JSON события),
    внутри упаковывается в envelope и идёт тем же пайплайном.

  Инвариант (CLAUDE.md): никакой тяжёлой работы в запросе — auth,
  rate limit (ADR-0009), лимиты размеров, распаковка, XADD в буфер,
  ответ. Разбор items и вся обработка — в пайплайне.
  """

  use SwatterWeb, :controller

  alias Swatter.Ingest.{Auth, Buffer, Decompress, Envelope, RateLimiter}
  alias Swatter.Projects

  # ingest-протокол не входит в OpenAPI-спеку dashboard API (ADR-0008);
  # nil глушит предупреждения Paths.from_router
  @doc false
  def open_api_operation(_action), do: nil

  def envelope(conn, %{"project_id" => project_id_param}) do
    with {:ok, ctx, conn} <- prelude(conn, project_id_param),
         {:ok, header} <- Envelope.parse_header(ctx.payload),
         :ok <- Buffer.enqueue(ctx.project_id, ctx.key_id, ctx.payload, header) do
      json(conn, %{id: Envelope.event_id(header)})
    else
      error -> respond_error(conn, error)
    end
  end

  def store(conn, %{"project_id" => project_id_param}) do
    with {:ok, ctx, conn} <- prelude(conn, project_id_param),
         {:ok, event} when is_map(event) <- decode_event(ctx.payload),
         event_id = Envelope.event_id(event),
         envelope = wrap_in_envelope(event_id, ctx.payload),
         :ok <- Buffer.enqueue(ctx.project_id, ctx.key_id, envelope, %{}) do
      json(conn, %{id: event_id})
    else
      error -> respond_error(conn, error)
    end
  end

  @doc false
  # Preflight обрабатывает IngestCORS до контроллера; маршрут нужен,
  # чтобы OPTIONS дошёл до пайплайна, а не упал в 404
  def preflight(conn, _params), do: send_resp(conn, 204, "")

  # Общий пролог: project_id → auth → ключ → rate limit → тело → распаковка.
  # Лимит проверяется ДО чтения тела: превышение не тратит полосу на upload.
  defp prelude(conn, project_id_param) do
    limits = Application.fetch_env!(:swatter, :ingest)

    with {:ok, project_id} <- parse_project_id(project_id_param),
         {:ok, auth} <- Auth.from_conn(conn),
         {:key, key} when not is_nil(key) <-
           {:key, Projects.get_active_key(project_id, auth.public_key)},
         :ok <- RateLimiter.check(key),
         {:ok, body, conn} <- read_full_body(conn, limits[:max_compressed_bytes]),
         {:ok, payload} <-
           Decompress.maybe_decompress(
             body,
             get_req_header(conn, "content-encoding"),
             limits[:max_envelope_bytes]
           ) do
      {:ok, %{project_id: project_id, key_id: key.id, payload: payload}, conn}
    end
  end

  # Auth-отказы едины (401), без различения "нет проекта"/"чужой ключ" —
  # чтобы не давать перебирать project_id
  defp respond_error(conn, error) do
    case error do
      {:error, :invalid_project_id} -> deny(conn, 401, "invalid authentication")
      {:error, :missing_auth} -> deny(conn, 401, "missing authentication")
      {:key, nil} -> deny(conn, 401, "invalid authentication")
      {:deny, retry_after} -> rate_limited(conn, retry_after)
      {:error, :payload_too_large} -> deny(conn, 413, "payload too large")
      {:error, :invalid_compression} -> deny(conn, 400, "invalid compressed payload")
      {:error, :invalid_envelope} -> deny(conn, 400, "invalid envelope")
      {:error, :invalid_event} -> deny(conn, 400, "invalid event payload")
      {:error, :read_error} -> deny(conn, 400, "could not read request body")
      {:error, :buffer_unavailable} -> retry_later(conn)
    end
  end

  defp decode_event(payload) do
    case Jason.decode(payload) do
      {:ok, event} when is_map(event) -> {:ok, event}
      _ -> {:error, :invalid_event}
    end
  end

  # /store/ несёт голое событие — упаковываем в envelope, чтобы пайплайн
  # видел единственный формат
  defp wrap_in_envelope(event_id, event_json) do
    header = Jason.encode!(%{"event_id" => event_id})
    item_header = Jason.encode!(%{"type" => "event", "length" => byte_size(event_json)})
    header <> "\n" <> item_header <> "\n" <> event_json <> "\n"
  end

  defp parse_project_id(param) do
    case Integer.parse(param) do
      {id, ""} when id > 0 -> {:ok, id}
      _ -> {:error, :invalid_project_id}
    end
  end

  defp read_full_body(conn, max_bytes), do: read_full_body(conn, [], 0, max_bytes)

  defp read_full_body(conn, acc, size, max_bytes) do
    case read_body(conn, length: 1_000_000, read_length: 1_000_000) do
      {:ok, chunk, conn} ->
        if size + byte_size(chunk) > max_bytes do
          {:error, :payload_too_large}
        else
          {:ok, IO.iodata_to_binary([acc | chunk]), conn}
        end

      {:more, chunk, conn} ->
        if size + byte_size(chunk) > max_bytes do
          {:error, :payload_too_large}
        else
          read_full_body(conn, [acc | chunk], size + byte_size(chunk), max_bytes)
        end

      {:error, _reason} ->
        {:error, :read_error}
    end
  end

  defp deny(conn, status, detail) do
    conn
    |> put_status(status)
    |> json(%{detail: detail})
  end

  defp rate_limited(conn, retry_after) do
    # форма Sentry: SDK буферизуют и ретраят; пустые категории = все, scope=key
    conn
    |> put_resp_header("retry-after", Integer.to_string(retry_after))
    |> put_resp_header("x-sentry-rate-limits", "#{retry_after}::key")
    |> put_status(429)
    |> json(%{detail: "rate limit exceeded"})
  end

  defp retry_later(conn) do
    # Официальные SDK умеют Retry-After: событие останется у клиента
    conn
    |> put_resp_header("retry-after", "30")
    |> put_status(503)
    |> json(%{detail: "temporarily unavailable, retry later"})
  end
end
