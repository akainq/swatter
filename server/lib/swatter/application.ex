defmodule Swatter.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        SwatterWeb.Telemetry,
        Swatter.Repo,
        Swatter.EventsRepo,
        {Redix,
         {Application.fetch_env!(:swatter, :redis_url), [name: Swatter.Ingest.Buffer.conn_name()]}},
        {DNSCluster, query: Application.get_env(:swatter, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Swatter.PubSub},
        # ETS-кэш sourcemap (ADR-0011): владелец таблицы, загрузка — в вызывателе
        Swatter.Symbolication.Cache,
        # ETS-кэш настроек алертов (ADR-0013): частотное правило смотрит каждое событие
        Swatter.Alerts.SettingsCache,
        # Фоновые задачи (ADR-0013/0016): доставка алертов и AI-анализ
        {Oban, Application.fetch_env!(:swatter, Oban)}
      ] ++
        pipeline_children() ++
        [
          # Start to serve requests, typically the last entry
          SwatterWeb.Endpoint
        ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Swatter.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # В тестах пайплайн поднимают сами интеграционные тесты (start_supervised)
  defp pipeline_children do
    if Application.get_env(:swatter, :start_pipeline, true) do
      [Swatter.Pipeline]
    else
      []
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    SwatterWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
