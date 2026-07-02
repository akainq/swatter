defmodule SwatterWeb.ApiSpec do
  @moduledoc """
  OpenAPI-спека dashboard API (ADR-0008). Генерируется из кода;
  файл для генерации TS-типов: `mix openapi.spec.json --spec
  SwatterWeb.ApiSpec priv/openapi.json` (свежесть проверяет CI).
  """

  alias OpenApiSpex.{Info, OpenApi, Paths, Server}

  @behaviour OpenApi

  @impl OpenApi
  def spec do
    %OpenApi{
      info: %Info{
        title: "Swatter Dashboard API",
        version: "0.1.0",
        description: """
        REST в стиле Sentry под /api/0/. Пагинация — keyset-курсор:
        при наличии следующей страницы ответ несёт заголовок
        `Link: <url>; rel="next"; results="true"; cursor="..."`.
        До 1.0 контракт нестабилен.
        """
      },
      servers: [%Server{url: "/"}],
      paths: Paths.from_router(SwatterWeb.Router)
    }
    |> OpenApiSpex.resolve_schema_modules()
  end
end
