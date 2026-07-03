defmodule SwatterWeb.PerformanceApiTest do
  # async: false — тесты делят таблицу spans в ClickHouse
  use SwatterWeb.ConnCase, async: false

  import OpenApiSpex.TestAssertions
  import Swatter.AccountsFixtures
  import Swatter.ProjectsFixtures

  alias Swatter.EventsRepo
  alias Swatter.Spans.Span

  setup %{conn: conn} do
    EventsRepo.query!("TRUNCATE TABLE spans")
    EventsRepo.query!("TRUNCATE TABLE events")
    {project, _key} = project_fixture()
    org = Swatter.Repo.get!(Swatter.Projects.Organization, project.organization_id)
    user = member_fixture(org)
    %{conn: log_in_user(conn, user), org: org, project: project}
  end

  defp insert_error!(project, trace_id, opts \\ []) do
    at = Keyword.get(opts, :at, DateTime.utc_now())

    EventsRepo.insert_all(Swatter.Events.Event, [
      %{
        org_id: project.organization_id,
        project_id: project.id,
        issue_id: Keyword.get(opts, :issue_id, 111),
        event_id: random_hex(32),
        timestamp: at,
        received_at: at,
        level: "error",
        message: "",
        exception_type: Keyword.get(opts, :type, "PaymentError"),
        exception_value: "boom",
        culprit: "",
        release: "",
        environment: "production",
        platform: "node",
        sdk_name: "",
        sdk_version: "",
        user_id: "",
        user_email: "",
        user_ip: "",
        tags: %{},
        trace_id: trace_id,
        payload: "{}"
      }
    ])
  end

  defp insert_segment!(project, name, duration_ms, opts \\ []) do
    at = Keyword.get(opts, :at, DateTime.utc_now())
    span_id = Keyword.get(opts, :span_id, random_hex(16))

    EventsRepo.insert_all(Span, [
      %{
        org_id: project.organization_id,
        project_id: project.id,
        trace_id: Keyword.get(opts, :trace_id, random_hex(32)),
        span_id: span_id,
        parent_span_id: Keyword.get(opts, :parent_span_id, ""),
        segment_id: Keyword.get(opts, :segment_id, span_id),
        is_segment: Keyword.get(opts, :is_segment, 1),
        transaction_name: name,
        op: Keyword.get(opts, :op, "http.server"),
        description: name,
        status: "ok",
        start_ts: at,
        end_ts: DateTime.add(at, round(duration_ms * 1000), :microsecond),
        duration_ms: duration_ms * 1.0,
        environment: "production",
        release: "",
        platform: "node",
        tags: %{},
        received_at: at
      }
    ])
  end

  defp random_hex(chars) do
    chars |> div(2) |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
  end

  defp api_spec, do: SwatterWeb.ApiSpec.spec()

  test "агрегаты: count/p50/p95/rpm по корневым спанам за окно", %{
    conn: conn,
    org: org,
    project: project
  } do
    insert_segment!(project, "GET /a", 100)
    insert_segment!(project, "GET /a", 200)
    insert_segment!(project, "GET /a", 300)
    insert_segment!(project, "GET /b", 50)
    # не-сегмент не должен попадать в агрегаты
    insert_segment!(project, "GET /a", 999, is_segment: 0)
    # событие за пределами суточного окна
    insert_segment!(project, "GET /old", 10, at: DateTime.add(DateTime.utc_now(), -25 * 3600))

    body =
      conn
      |> get("/api/0/projects/#{org.slug}/#{project.slug}/performance/transactions")
      |> json_response(200)

    assert_schema(body, "TransactionStatList", api_spec())

    names = Enum.map(body, & &1["transaction"])
    assert "GET /a" in names
    assert "GET /b" in names
    refute "GET /old" in names

    a = Enum.find(body, &(&1["transaction"] == "GET /a"))
    assert a["count"] == 3
    assert_in_delta a["p50"], 200.0, 1.0
    assert a["p95"] >= a["p50"]
    assert a["p95"] <= 300.0
    assert_in_delta a["rpm"], 3 / 1440, 0.01

    # самые частые сверху
    assert hd(names) == "GET /a"
  end

  test "окно 1h отсекает старые сегменты", %{conn: conn, org: org, project: project} do
    insert_segment!(project, "GET /fresh", 100)
    insert_segment!(project, "GET /stale", 100, at: DateTime.add(DateTime.utc_now(), -2 * 3600))

    body =
      conn
      |> get("/api/0/projects/#{org.slug}/#{project.slug}/performance/transactions?window=1h")
      |> json_response(200)

    names = Enum.map(body, & &1["transaction"])
    assert names == ["GET /fresh"]
  end

  test "чужая организация → 404", %{project: project} do
    other = member_fixture(org_fixture())
    conn = log_in_user(Phoenix.ConnTest.build_conn(), other)
    org = Swatter.Repo.get!(Swatter.Projects.Organization, project.organization_id)

    conn = get(conn, "/api/0/projects/#{org.slug}/#{project.slug}/performance/transactions")
    assert json_response(conn, 404)
  end

  test "traces: сегменты транзакции, медленные сверху", %{
    conn: conn,
    org: org,
    project: project
  } do
    insert_segment!(project, "GET /a", 100)
    insert_segment!(project, "GET /a", 300)
    insert_segment!(project, "GET /a", 200)
    insert_segment!(project, "GET /other", 999)

    body =
      conn
      |> get(
        "/api/0/projects/#{org.slug}/#{project.slug}/performance/traces?" <>
          URI.encode_query(transaction: "GET /a")
      )
      |> json_response(200)

    assert_schema(body, "TraceSummaryList", api_spec())
    assert Enum.map(body, & &1["durationMs"]) == [300.0, 200.0, 100.0]
  end

  test "trace: спаны по организации кросс-проектно; чужая организация — 404", %{
    conn: conn,
    org: org,
    project: project
  } do
    trace_id = random_hex(32)
    segment_id = random_hex(16)

    # фронтовый сегмент в этом проекте + бэкендовый в соседнем проекте той же org
    insert_segment!(project, "pageload /checkout", 400,
      trace_id: trace_id,
      span_id: segment_id
    )

    insert_segment!(project, "fetch /api/pay", 120,
      trace_id: trace_id,
      is_segment: 0,
      parent_span_id: segment_id,
      segment_id: segment_id,
      op: "http.client"
    )

    {backend, _} = project_fixture(org)
    insert_segment!(backend, "POST /api/pay", 90, trace_id: trace_id)

    body =
      conn |> get("/api/0/organizations/#{org.slug}/traces/#{trace_id}") |> json_response(200)

    assert_schema(body, "Trace", api_spec())

    assert body["traceId"] == trace_id
    assert length(body["spans"]) == 3

    slugs = body["spans"] |> Enum.map(& &1["projectSlug"]) |> Enum.uniq() |> Enum.sort()
    assert slugs == Enum.sort([project.slug, backend.slug])

    # участник другой организации трейс не видит
    stranger = member_fixture(org_fixture())
    other_conn = log_in_user(Phoenix.ConnTest.build_conn(), stranger)
    other_conn = get(other_conn, "/api/0/organizations/#{org.slug}/traces/#{trace_id}")
    assert json_response(other_conn, 404)

    # несуществующий трейс — 404
    empty = get(conn, "/api/0/organizations/#{org.slug}/traces/#{random_hex(32)}")
    assert json_response(empty, 404)
  end

  test "ошибки трейса: в ответе trace и на /errors, кросс-проектно", %{
    conn: conn,
    org: org,
    project: project
  } do
    trace_id = random_hex(32)
    insert_segment!(project, "GET /checkout", 100, trace_id: trace_id)

    {backend, _} = project_fixture(org)
    insert_error!(backend, trace_id, issue_id: 42)
    # ошибка другого трейса не попадает
    insert_error!(project, random_hex(32))

    body =
      conn |> get("/api/0/organizations/#{org.slug}/traces/#{trace_id}") |> json_response(200)

    assert_schema(body, "Trace", api_spec())
    assert [error] = body["errors"]
    assert error["title"] == "PaymentError: boom"
    assert error["issueId"] == "42"
    assert error["projectSlug"] == backend.slug

    errors =
      conn
      |> get("/api/0/organizations/#{org.slug}/traces/#{trace_id}/errors")
      |> json_response(200)

    assert_schema(errors, "RelatedErrorList", api_spec())
    assert length(errors) == 1
  end
end
