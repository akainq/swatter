defmodule Swatter.Ingest.RateLimiter do
  @moduledoc """
  Per-key rate limiting приёма (ADR-0009): fixed window в Redis
  (`INCR` + `EXPIRE`), fail-open при недоступном Redis.
  """

  require Logger

  alias Swatter.Ingest.Buffer
  alias Swatter.Projects.ProjectKey

  @spec check(ProjectKey.t()) :: :ok | {:deny, pos_integer()}
  def check(%ProjectKey{} = key) do
    {count, window} = limits_for(key)
    now = System.system_time(:second)
    window_start = div(now, window) * window
    redis_key = "swatter:rl:#{key.id}:#{window_start}"

    commands = [
      ["INCR", redis_key],
      ["EXPIRE", redis_key, Integer.to_string(window + 1)]
    ]

    case Redix.pipeline(Buffer.conn_name(), commands) do
      {:ok, [seen, _]} when is_integer(seen) and seen > count ->
        {:deny, max(window_start + window - now, 1)}

      {:ok, _} ->
        :ok

      {:error, reason} ->
        # fail-open: если Redis лежит, буфер (ADR-0005) всё равно ответит 503;
        # ложные 429 из-за сетевой икоты вреднее пропущенной проверки
        Logger.warning("rate limiter unavailable, failing open: #{inspect(reason)}")
        :ok
    end
  end

  defp limits_for(key) do
    defaults = Application.fetch_env!(:swatter, :ingest)[:rate_limit]

    {key.rate_limit_count || defaults[:count],
     key.rate_limit_window_seconds || defaults[:window_seconds]}
  end
end
