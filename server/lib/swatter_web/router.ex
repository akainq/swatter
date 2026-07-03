defmodule SwatterWeb.Router do
  use SwatterWeb, :router

  import SwatterWeb.Plugs.Auth, only: [fetch_current_user: 2, require_authenticated: 2]

  # Dashboard API (/api/0/..., ADR-0008): JSON-парсеры + сессия (ADR-0007)
  pipeline :api do
    plug :accepts, ["json"]

    plug Plug.Parsers,
      parsers: [:urlencoded, :multipart, :json],
      pass: ["*/*"],
      json_decoder: Phoenix.json_library()

    plug OpenApiSpex.Plug.PutApiSpec, module: SwatterWeb.ApiSpec
    plug :fetch_session
    plug :fetch_current_user
  end

  pipeline :authenticated do
    plug :require_authenticated
  end

  # загрузка sourcemap-артефактов (ADR-0012): multipart с бо́льшим лимитом,
  # чем у обычного JSON-API
  pipeline :api_upload do
    plug :accepts, ["json"]

    plug Plug.Parsers,
      parsers: [:multipart],
      length: 35_000_000

    plug OpenApiSpex.Plug.PutApiSpec, module: SwatterWeb.ApiSpec
    plug :fetch_session
    plug :fetch_current_user
  end

  # Sentry ingest (ADR-0001): тело читается сырым (envelope — не JSON),
  # поэтому Plug.Parsers здесь нет; CORS — для браузерных SDK
  pipeline :ingest do
    plug SwatterWeb.Plugs.IngestCORS
  end

  scope "/api", SwatterWeb do
    pipe_through :ingest

    post "/:project_id/envelope", IngestController, :envelope
    options "/:project_id/envelope", IngestController, :preflight
    post "/:project_id/store", IngestController, :store
    options "/:project_id/store", IngestController, :preflight
  end

  scope "/api/0/auth", SwatterWeb do
    pipe_through :api

    get "/setup", AuthController, :setup_status
    post "/setup", AuthController, :setup
    post "/login", AuthController, :login
  end

  scope "/api/0/auth", SwatterWeb do
    pipe_through [:api, :authenticated]

    post "/logout", AuthController, :logout
    get "/me", AuthController, :me
  end

  scope "/api/0", SwatterWeb do
    pipe_through [:api, :authenticated]

    get "/organizations", OrganizationController, :index
    get "/organizations/:org_slug/projects", ProjectController, :index
    post "/organizations/:org_slug/projects", ProjectController, :create
    put "/projects/:org_slug/:project_slug", ProjectController, :update
    get "/projects/:org_slug/:project_slug/issues", IssueController, :index
    get "/projects/:org_slug/:project_slug/filters", IssueController, :filters
    get "/projects/:org_slug/:project_slug/releases", ReleaseController, :index
    get "/projects/:org_slug/:project_slug/releases/:version", ReleaseController, :show

    get "/projects/:org_slug/:project_slug/performance/transactions",
        PerformanceController,
        :transactions

    get "/projects/:org_slug/:project_slug/performance/traces",
        PerformanceController,
        :traces

    get "/organizations/:org_slug/traces/:trace_id", PerformanceController, :trace

    get "/projects/:org_slug/:project_slug/alert-settings", AlertSettingsController, :show
    put "/projects/:org_slug/:project_slug/alert-settings", AlertSettingsController, :update
    get "/issues/:issue_id", IssueController, :show
    put "/issues/:issue_id", IssueController, :update
    post "/issues/:issue_id/analyze", IssueController, :analyze
    get "/issues/:issue_id/events", EventController, :index
    get "/issues/:issue_id/events/latest", EventController, :latest
  end

  scope "/api/0", SwatterWeb do
    pipe_through [:api_upload, :authenticated]

    post "/projects/:org_slug/:project_slug/artifacts", ArtifactController, :create
  end

  scope "/api/0" do
    pipe_through :api

    get "/openapi.json", OpenApiSpex.Plug.RenderSpec, []
  end

  # liveness для docker/Coolify healthcheck
  get "/health", SwatterWeb.HealthController, :show

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:swatter, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through [:fetch_session, :protect_from_forgery]

      live_dashboard "/dashboard", metrics: SwatterWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  # Фолбэк клиентского роутинга SPA — строго последним: реальные файлы
  # отдал Plug.Static в endpoint, /api-маршруты сматчились выше
  get "/*path", SwatterWeb.SPAController, :index
end
