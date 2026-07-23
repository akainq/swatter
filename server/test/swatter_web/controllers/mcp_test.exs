defmodule SwatterWeb.MCPTest do
  # async: false — делим таблицы events/spans в ClickHouse
  use SwatterWeb.ConnCase, async: false

  import Swatter.AccountsFixtures
  import Swatter.ProjectsFixtures

  alias Swatter.{Accounts, EventsRepo, Issues}

  setup %{conn: conn} do
    EventsRepo.query!("TRUNCATE TABLE events")
    EventsRepo.query!("TRUNCATE TABLE spans")
    {project, _key} = project_fixture()
    org = Swatter.Repo.get!(Swatter.Projects.Organization, project.organization_id)
    user = member_fixture(org)
    {:ok, token, _record} = Accounts.create_api_token(user, "mcp-test")
    %{conn: conn, org: org, project: project, user: user, token: token}
  end

  defp rpc(conn, token, body) do
    conn
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("content-type", "application/json")
    |> post("/mcp", Jason.encode!(body))
  end

  defp call_tool(conn, token, name, args, id \\ 7) do
    response =
      rpc(conn, token, %{
        jsonrpc: "2.0",
        id: id,
        method: "tools/call",
        params: %{name: name, arguments: args}
      })
      |> json_response(200)

    result = response["result"]
    {result["isError"], result["content"] |> hd() |> Map.fetch!("text")}
  end

  defp issue!(project, attrs \\ %{}) do
    {:ok, issue} =
      Issues.upsert_from_event(
        Map.merge(
          %{
            fingerprint_hash: "fp-mcp-#{System.unique_integer([:positive])}",
            grouping_version: 1,
            title: "PaymentError: card declined",
            culprit: "billing.ts in chargeCard",
            level: "error",
            timestamp: DateTime.utc_now()
          },
          attrs
        ),
        project.organization_id,
        project.id
      )

    issue
  end

  defp insert_event!(project, issue, opts \\ []) do
    at = DateTime.utc_now()

    payload = %{
      "exception" => %{
        "values" => [
          %{
            "type" => "PaymentError",
            "value" => "card declined",
            "stacktrace" => %{
              "frames" => [
                %{"filename" => "node:internal", "function" => "run", "lineno" => 1},
                %{
                  "filename" => "src/billing.ts",
                  "function" => "chargeCard",
                  "lineno" => 42,
                  "in_app" => true,
                  "context_line" => "await gateway.charge(card)",
                  "data" => %{"symbolicated" => true}
                }
              ]
            }
          }
        ]
      },
      "breadcrumbs" => [%{"category" => "http", "message" => "POST /pay"}]
    }

    EventsRepo.insert_all(Swatter.Events.Event, [
      %{
        org_id: project.organization_id,
        project_id: project.id,
        issue_id: issue.id,
        event_id: random_hex(32),
        timestamp: at,
        received_at: at,
        level: "error",
        message: "",
        exception_type: "PaymentError",
        exception_value: "card declined",
        culprit: issue.culprit,
        release: "api@1.0.0",
        environment: "production",
        platform: "node",
        sdk_name: "",
        sdk_version: "",
        user_id: "",
        user_email: "",
        user_ip: "",
        tags: %{"server_name" => "web-01"},
        trace_id: Keyword.get(opts, :trace_id, ""),
        payload: Jason.encode!(payload)
      }
    ])
  end

  defp random_hex(chars) do
    chars |> div(2) |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
  end

  test "без токена — 401 с WWW-Authenticate", %{conn: conn} do
    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/mcp", Jason.encode!(%{jsonrpc: "2.0", id: 1, method: "ping"}))

    assert json_response(conn, 401)
    assert get_resp_header(conn, "www-authenticate") == ["Bearer"]
  end

  test "initialize: эхо поддерживаемой версии, serverInfo", %{conn: conn, token: token} do
    response =
      rpc(conn, token, %{
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: %{protocolVersion: "2025-06-18", capabilities: %{}}
      })
      |> json_response(200)

    assert response["result"]["protocolVersion"] == "2025-06-18"
    assert response["result"]["serverInfo"]["name"] == "swatter"
    assert response["result"]["capabilities"]["tools"] == %{}

    # неизвестная версия → предлагаем свою новейшую
    response =
      rpc(conn, token, %{
        jsonrpc: "2.0",
        id: 2,
        method: "initialize",
        params: %{protocolVersion: "1999-01-01"}
      })
      |> json_response(200)

    assert response["result"]["protocolVersion"] == "2025-06-18"
  end

  test "уведомления → 202 без тела; неизвестный метод → -32601", %{conn: conn, token: token} do
    conn2 = rpc(conn, token, %{jsonrpc: "2.0", method: "notifications/initialized"})
    assert conn2.status == 202

    response =
      rpc(conn, token, %{jsonrpc: "2.0", id: 3, method: "no/such"}) |> json_response(200)

    assert response["error"]["code"] == -32601
  end

  test "tools/list — четыре тула", %{conn: conn, token: token} do
    response =
      rpc(conn, token, %{jsonrpc: "2.0", id: 4, method: "tools/list"}) |> json_response(200)

    names = response["result"]["tools"] |> Enum.map(& &1["name"]) |> Enum.sort()
    assert names == ["get_issue", "get_trace", "list_issues", "resolve_issue"]
  end

  test "get_issue по ссылке: стек с контекстом, теги, breadcrumbs, AI", %{
    conn: conn,
    token: token,
    org: org,
    project: project
  } do
    issue = issue!(project)
    insert_event!(project, issue)

    {:ok, _} =
      Swatter.AI.store_ok(
        issue.id,
        %{summary: "Гейтвей отклонил карту", severity: "high"},
        "glm-4.6"
      )

    url = "http://localhost:4002/#{org.slug}/#{project.slug}/issues/#{issue.id}"
    {is_error, text} = call_tool(conn, token, "get_issue", %{"issue" => url})

    refute is_error
    assert text =~ "Issue ##{issue.id}: PaymentError: card declined"
    assert text =~ "Stack trace"

    # верхний кадр (in-app, символикованный) — первым, с контекстом
    assert text =~ "at chargeCard (src/billing.ts:42) *"
    assert text =~ "> await gateway.charge(card)"
    assert text =~ "server_name=web-01"
    assert text =~ "[http] POST /pay"
    assert text =~ "AI analysis (glm-4.6)"
    assert text =~ "Гейтвей отклонил карту"
  end

  test "чужой issue неотличим от несуществующего", %{conn: conn, project: project} do
    issue = issue!(project)

    stranger = member_fixture(org_fixture())
    {:ok, foreign_token, _} = Accounts.create_api_token(stranger, "foreign")

    {is_error, text} = call_tool(conn, foreign_token, "get_issue", %{"issue" => "#{issue.id}"})
    assert is_error
    assert text =~ "not found"
  end

  test "list_issues ищет по query; resolve_issue закрывает", %{
    conn: conn,
    token: token,
    project: project
  } do
    issue = issue!(project, %{title: "TimeoutError: upstream slow"})
    _other = issue!(project)

    {is_error, text} =
      call_tool(conn, token, "list_issues", %{"project" => project.slug, "query" => "Timeout"})

    refute is_error
    assert text =~ "##{issue.id}"
    assert text =~ "TimeoutError"
    refute text =~ "PaymentError"

    {is_error, text} = call_tool(conn, token, "resolve_issue", %{"issue" => "#{issue.id}"})
    refute is_error
    assert text =~ "resolved"
    assert Issues.get_issue(issue.id).status == "resolved"
  end

  test "get_trace: дерево спанов + ошибки трейса", %{
    conn: conn,
    token: token,
    project: project
  } do
    trace_id = random_hex(32)
    segment_id = random_hex(16)
    at = DateTime.utc_now()

    EventsRepo.insert_all(Swatter.Spans.Span, [
      %{
        org_id: project.organization_id,
        project_id: project.id,
        trace_id: trace_id,
        span_id: segment_id,
        parent_span_id: "",
        segment_id: segment_id,
        is_segment: 1,
        transaction_name: "GET /checkout",
        op: "http.server",
        description: "GET /checkout",
        status: "ok",
        start_ts: at,
        end_ts: DateTime.add(at, 100_000, :microsecond),
        duration_ms: 100.0,
        environment: "production",
        release: "",
        platform: "node",
        tags: %{},
        received_at: at
      },
      %{
        org_id: project.organization_id,
        project_id: project.id,
        trace_id: trace_id,
        span_id: random_hex(16),
        parent_span_id: segment_id,
        segment_id: segment_id,
        is_segment: 0,
        transaction_name: "GET /checkout",
        op: "db.query",
        description: "SELECT 1",
        status: "ok",
        start_ts: at,
        end_ts: DateTime.add(at, 40_000, :microsecond),
        duration_ms: 40.0,
        environment: "production",
        release: "",
        platform: "node",
        tags: %{},
        received_at: at
      }
    ])

    issue = issue!(project)
    insert_event!(project, issue, trace_id: trace_id)

    {is_error, text} = call_tool(conn, token, "get_trace", %{"trace" => trace_id})

    refute is_error
    assert text =~ "Trace #{trace_id}"
    assert text =~ "* http.server GET /checkout"
    assert text =~ "  - db.query SELECT 1"
    assert text =~ "Errors in this trace"
    assert text =~ "##{issue.id}"
  end
end
