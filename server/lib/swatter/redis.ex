defmodule Swatter.Redis do
  @moduledoc false

  @doc """
  Keyword-опции для Redix из redis-URL (`redis://[user:pass@]host[:port]`).
  Нужно потребителям, принимающим только keyword (off_broadway_redis_stream).
  """
  def opts_from_url(url) do
    uri = URI.parse(url)
    opts = [host: uri.host, port: uri.port || 6379]

    case uri.userinfo do
      nil -> opts
      info -> opts ++ [password: info |> String.split(":") |> List.last()]
    end
  end
end
