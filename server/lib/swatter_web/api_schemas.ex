defmodule SwatterWeb.ApiSchemas do
  @moduledoc "OpenAPI-схемы ответов dashboard API (ADR-0008)."

  alias OpenApiSpex.Schema

  require OpenApiSpex

  defmodule Organization do
    @moduledoc false
    OpenApiSpex.schema(%{
      title: "Organization",
      type: :object,
      properties: %{
        id: %Schema{type: :string},
        slug: %Schema{type: :string},
        name: %Schema{type: :string}
      },
      required: [:id, :slug, :name]
    })
  end

  defmodule Project do
    @moduledoc false
    OpenApiSpex.schema(%{
      title: "Project",
      type: :object,
      properties: %{
        id: %Schema{type: :string},
        slug: %Schema{type: :string},
        name: %Schema{type: :string},
        platform: %Schema{type: :string, nullable: true},
        dsn: %Schema{type: :string, nullable: true, description: "DSN первого активного ключа"},
        unresolvedIssues: %Schema{
          type: :integer,
          nullable: true,
          description: "Счётчик unresolved issues (в списке проектов)"
        },
        events24h: %Schema{
          type: :integer,
          nullable: true,
          description: "События за последние 24 часа (в списке проектов)"
        }
      },
      required: [:id, :slug, :name]
    })
  end

  defmodule Artifact do
    @moduledoc false
    OpenApiSpex.schema(%{
      title: "Artifact",
      type: :object,
      properties: %{
        id: %Schema{type: :string},
        debugId: %Schema{type: :string},
        type: %Schema{type: :string, enum: ["source_map", "minified_source"]},
        name: %Schema{type: :string, nullable: true},
        size: %Schema{type: :integer, description: "размер распакованного контента"}
      },
      required: [:id, :debugId, :type, :size]
    })
  end

  defmodule Release do
    @moduledoc false
    OpenApiSpex.schema(%{
      title: "Release",
      type: :object,
      properties: %{
        id: %Schema{type: :string},
        version: %Schema{type: :string},
        ordinal: %Schema{type: :integer, description: "порядок в проекте (больше = новее)"},
        firstEventAt: %Schema{type: :string, format: :"date-time", nullable: true},
        newIssues: %Schema{type: :integer, nullable: true, description: "новых issues в релизе"}
      },
      required: [:id, :version, :ordinal]
    })
  end

  defmodule ReleaseDetail do
    @moduledoc false
    OpenApiSpex.schema(%{
      title: "ReleaseDetail",
      type: :object,
      properties: %{
        id: %Schema{type: :string},
        version: %Schema{type: :string},
        ordinal: %Schema{type: :integer},
        firstEventAt: %Schema{type: :string, format: :"date-time", nullable: true},
        newIssues: %Schema{type: :array, items: SwatterWeb.ApiSchemas.Issue}
      },
      required: [:id, :version, :ordinal, :newIssues]
    })
  end

  defmodule FilterValues do
    @moduledoc false
    OpenApiSpex.schema(%{
      title: "FilterValues",
      type: :object,
      properties: %{
        environments: %Schema{type: :array, items: %Schema{type: :string}},
        releases: %Schema{type: :array, items: %Schema{type: :string}}
      },
      required: [:environments, :releases]
    })
  end

  defmodule ProjectUpdateRequest do
    @moduledoc false
    OpenApiSpex.schema(%{
      title: "ProjectUpdateRequest",
      type: :object,
      properties: %{
        name: %Schema{type: :string},
        platform: %Schema{type: :string, nullable: true}
      },
      required: [:name]
    })
  end

  defmodule AIAnalysis do
    @moduledoc false
    OpenApiSpex.schema(%{
      title: "AIAnalysis",
      description: "AI-анализ issue (ADR-0016), запускается по запросу",
      type: :object,
      properties: %{
        status: %Schema{type: :string, enum: ["pending", "ok", "error"]},
        summary: %Schema{type: :string, nullable: true},
        probableCause: %Schema{type: :string, nullable: true},
        severity: %Schema{
          type: :string,
          nullable: true,
          enum: ["low", "medium", "high", "critical"]
        },
        suggestedFix: %Schema{type: :string, nullable: true},
        model: %Schema{type: :string, nullable: true},
        error: %Schema{type: :string, nullable: true},
        analyzedAt: %Schema{type: :string, format: :"date-time", nullable: true}
      },
      required: [:status]
    })
  end

  defmodule Issue do
    @moduledoc false
    OpenApiSpex.schema(%{
      title: "Issue",
      type: :object,
      properties: %{
        id: %Schema{type: :string},
        title: %Schema{type: :string},
        culprit: %Schema{type: :string},
        level: %Schema{type: :string, enum: ["fatal", "error", "warning", "info", "debug"]},
        status: %Schema{type: :string, enum: ["unresolved", "resolved", "ignored"]},
        count: %Schema{type: :integer, description: "times_seen"},
        regressed: %Schema{type: :boolean, description: "вернулся в релизе новее закрытия"},
        firstSeen: %Schema{type: :string, format: :"date-time"},
        lastSeen: %Schema{type: :string, format: :"date-time"},
        project: %Schema{
          type: :object,
          nullable: true,
          properties: %{id: %Schema{type: :string}, slug: %Schema{type: :string}}
        },
        aiAnalysis: %Schema{
          allOf: [SwatterWeb.ApiSchemas.AIAnalysis],
          nullable: true,
          description: "только в деталке; null, если анализ не запрашивался"
        },
        aiEnabled: %Schema{
          type: :boolean,
          nullable: true,
          description: "только в деталке: настроен ли AI на инстансе (ZAI_API_KEY)"
        }
      },
      required: [:id, :title, :culprit, :level, :status, :count, :firstSeen, :lastSeen]
    })
  end

  defmodule IssueList do
    @moduledoc false
    OpenApiSpex.schema(%{
      title: "IssueList",
      type: :array,
      items: SwatterWeb.ApiSchemas.Issue
    })
  end

  defmodule IssueUpdateRequest do
    @moduledoc false
    OpenApiSpex.schema(%{
      title: "IssueUpdateRequest",
      type: :object,
      properties: %{
        status: %Schema{type: :string, enum: ["unresolved", "resolved", "ignored"]}
      },
      required: [:status]
    })
  end

  defmodule TagEntry do
    @moduledoc false
    OpenApiSpex.schema(%{
      title: "TagEntry",
      type: :object,
      properties: %{key: %Schema{type: :string}, value: %Schema{type: :string}},
      required: [:key, :value]
    })
  end

  defmodule Event do
    @moduledoc false
    OpenApiSpex.schema(%{
      title: "Event",
      type: :object,
      properties: %{
        eventId: %Schema{type: :string},
        timestamp: %Schema{type: :string, format: :"date-time"},
        dateReceived: %Schema{type: :string, format: :"date-time"},
        level: %Schema{type: :string},
        message: %Schema{type: :string},
        platform: %Schema{type: :string},
        release: %Schema{type: :string},
        environment: %Schema{type: :string},
        traceId: %Schema{type: :string},
        sdk: %Schema{
          type: :object,
          properties: %{name: %Schema{type: :string}, version: %Schema{type: :string}}
        },
        user: %Schema{
          type: :object,
          properties: %{
            id: %Schema{type: :string},
            email: %Schema{type: :string},
            ipAddress: %Schema{type: :string}
          }
        },
        tags: %Schema{type: :array, items: SwatterWeb.ApiSchemas.TagEntry},
        exception: %Schema{
          nullable: true,
          description: "Структура exception из исходного события (values/stacktrace/frames)"
        },
        breadcrumbs: %Schema{nullable: true, description: "breadcrumbs из исходного события"},
        contexts: %Schema{nullable: true, description: "contexts из исходного события"}
      },
      required: [:eventId, :timestamp, :level]
    })
  end

  defmodule EventList do
    @moduledoc false
    OpenApiSpex.schema(%{
      title: "EventList",
      type: :array,
      items: SwatterWeb.ApiSchemas.Event
    })
  end

  defmodule Error do
    @moduledoc false
    OpenApiSpex.schema(%{
      title: "Error",
      type: :object,
      properties: %{detail: %Schema{type: :string}},
      required: [:detail]
    })
  end

  defmodule ProjectCreateRequest do
    @moduledoc false
    OpenApiSpex.schema(%{
      title: "ProjectCreateRequest",
      type: :object,
      properties: %{
        name: %Schema{type: :string},
        slug: %Schema{type: :string, pattern: "^[a-z0-9][a-z0-9-]*$"},
        platform: %Schema{type: :string, nullable: true}
      },
      required: [:name, :slug]
    })
  end

  defmodule TransactionStat do
    @moduledoc false
    OpenApiSpex.schema(%{
      title: "TransactionStat",
      description: "Агрегат по транзакции за окно (ADR-0014)",
      type: :object,
      properties: %{
        transaction: %Schema{type: :string},
        count: %Schema{type: :integer},
        rpm: %Schema{type: :number, description: "запросов в минуту за окно"},
        p50: %Schema{type: :number, description: "медиана длительности, мс"},
        p95: %Schema{type: :number, description: "95-й перцентиль длительности, мс"},
        lastSeen: %Schema{type: :string, format: :"date-time"}
      },
      required: [:transaction, :count, :rpm, :p50, :p95, :lastSeen]
    })
  end

  defmodule TransactionStatList do
    @moduledoc false
    OpenApiSpex.schema(%{
      title: "TransactionStatList",
      type: :array,
      items: SwatterWeb.ApiSchemas.TransactionStat
    })
  end

  defmodule TraceSummary do
    @moduledoc false
    OpenApiSpex.schema(%{
      title: "TraceSummary",
      type: :object,
      properties: %{
        traceId: %Schema{type: :string},
        startTs: %Schema{type: :string, format: :"date-time"},
        durationMs: %Schema{type: :number},
        status: %Schema{type: :string},
        environment: %Schema{type: :string},
        release: %Schema{type: :string}
      },
      required: [:traceId, :startTs, :durationMs]
    })
  end

  defmodule TraceSummaryList do
    @moduledoc false
    OpenApiSpex.schema(%{
      title: "TraceSummaryList",
      type: :array,
      items: SwatterWeb.ApiSchemas.TraceSummary
    })
  end

  defmodule TraceSpan do
    @moduledoc false
    OpenApiSpex.schema(%{
      title: "TraceSpan",
      type: :object,
      properties: %{
        spanId: %Schema{type: :string},
        parentSpanId: %Schema{type: :string},
        isSegment: %Schema{type: :boolean},
        transaction: %Schema{type: :string},
        op: %Schema{type: :string},
        description: %Schema{type: :string},
        status: %Schema{type: :string},
        startTs: %Schema{type: :string, format: :"date-time"},
        endTs: %Schema{type: :string, format: :"date-time"},
        durationMs: %Schema{type: :number},
        projectId: %Schema{type: :string},
        projectSlug: %Schema{type: :string, nullable: true}
      },
      required: [:spanId, :parentSpanId, :isSegment, :op, :startTs, :endTs, :durationMs]
    })
  end

  defmodule Trace do
    @moduledoc false
    OpenApiSpex.schema(%{
      title: "Trace",
      description: "Спаны трейса по всем проектам организации (ADR-0014)",
      type: :object,
      properties: %{
        traceId: %Schema{type: :string},
        spans: %Schema{type: :array, items: SwatterWeb.ApiSchemas.TraceSpan}
      },
      required: [:traceId, :spans]
    })
  end

  defmodule AlertSettings do
    @moduledoc false
    OpenApiSpex.schema(%{
      title: "AlertSettings",
      description: "Per-project настройки Telegram-алертов (ADR-0013)",
      type: :object,
      properties: %{
        enabled: %Schema{type: :boolean},
        telegramChatId: %Schema{type: :string, nullable: true},
        telegramConfigured: %Schema{
          type: :boolean,
          description: "задан ли общий TELEGRAM_BOT_TOKEN на инстансе"
        },
        onNewIssue: %Schema{type: :boolean},
        onRegression: %Schema{type: :boolean},
        frequencyThreshold: %Schema{
          type: :integer,
          nullable: true,
          description: "N событий за окно → алерт; null = правило выключено"
        },
        frequencyWindowSeconds: %Schema{type: :integer}
      },
      required: [
        :enabled,
        :telegramConfigured,
        :onNewIssue,
        :onRegression,
        :frequencyWindowSeconds
      ]
    })
  end

  defmodule AlertSettingsUpdateRequest do
    @moduledoc false
    OpenApiSpex.schema(%{
      title: "AlertSettingsUpdateRequest",
      type: :object,
      properties: %{
        enabled: %Schema{type: :boolean},
        telegramChatId: %Schema{type: :string, nullable: true},
        onNewIssue: %Schema{type: :boolean},
        onRegression: %Schema{type: :boolean},
        frequencyThreshold: %Schema{type: :integer, nullable: true},
        frequencyWindowSeconds: %Schema{type: :integer}
      }
    })
  end

  defmodule SetupStatus do
    @moduledoc false
    OpenApiSpex.schema(%{
      title: "SetupStatus",
      type: :object,
      properties: %{setupRequired: %Schema{type: :boolean}},
      required: [:setupRequired]
    })
  end

  defmodule SetupRequest do
    @moduledoc false
    OpenApiSpex.schema(%{
      title: "SetupRequest",
      type: :object,
      properties: %{
        email: %Schema{type: :string, format: :email},
        password: %Schema{type: :string, minLength: 8},
        name: %Schema{type: :string},
        orgName: %Schema{type: :string, default: "Swatter"},
        orgSlug: %Schema{type: :string, default: "swatter"}
      },
      required: [:email, :password]
    })
  end

  defmodule LoginRequest do
    @moduledoc false
    OpenApiSpex.schema(%{
      title: "LoginRequest",
      type: :object,
      properties: %{
        email: %Schema{type: :string, format: :email},
        password: %Schema{type: :string}
      },
      required: [:email, :password]
    })
  end

  defmodule CurrentUser do
    @moduledoc false
    OpenApiSpex.schema(%{
      title: "CurrentUser",
      type: :object,
      properties: %{
        id: %Schema{type: :string},
        email: %Schema{type: :string},
        name: %Schema{type: :string},
        memberships: %Schema{
          type: :array,
          items: %Schema{
            type: :object,
            properties: %{
              role: %Schema{type: :string, enum: ["owner", "admin", "member"]},
              organization: SwatterWeb.ApiSchemas.Organization
            },
            required: [:role, :organization]
          }
        }
      },
      required: [:id, :email, :memberships]
    })
  end
end
