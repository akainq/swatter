defmodule Swatter.Ingest.Buffer do
  @moduledoc """
  Durable-буфер между приёмом и пайплайном — Redis Stream (ADR-0005).

  `MAXLEN ~` ограничивает стрим: при переполнении Redis сбрасывает самые
  старые записи; потолок задаётся конфигом `:ingest / :stream_maxlen`.
  """

  require Logger

  @conn :redix_ingest

  @spec enqueue(pos_integer(), pos_integer(), binary(), map()) ::
          :ok | {:error, :buffer_unavailable}
  def enqueue(project_id, key_id, payload, envelope_header) do
    cfg = config()

    fields = [
      "project_id",
      Integer.to_string(project_id),
      "key_id",
      Integer.to_string(key_id),
      "received_at",
      Integer.to_string(System.system_time(:millisecond)),
      "sent_at",
      to_string(envelope_header["sent_at"] || ""),
      "payload",
      payload
    ]

    command =
      ["XADD", cfg[:stream], "MAXLEN", "~", Integer.to_string(cfg[:stream_maxlen]), "*"] ++
        fields

    case Redix.command(@conn, command) do
      {:ok, _entry_id} ->
        :ok

      {:error, reason} ->
        Logger.error("ingest buffer unavailable: #{inspect(reason)}")
        {:error, :buffer_unavailable}
    end
  end

  def conn_name, do: @conn

  def stream, do: config()[:stream]

  defp config, do: Application.fetch_env!(:swatter, :ingest)
end
