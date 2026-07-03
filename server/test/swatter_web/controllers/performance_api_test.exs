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
    {project, _key} = project_fixture()
    org = Swatter.Repo.get!(Swatter.Projects.Organization, project.organization_id)
    user = member_fixture(org)
    %{conn: log_in_user(conn, user), org: org, project: project}
  end

  defp insert_segment!(project, name, duration_ms, opts \\ []) do
    at = Keyword.get(opts, :at, DateTime.utc_now())
    span_id = random_hex(16)

    EventsRepo.insert_all(Span, [
      %{
        org_id: project.organization_id,
        project_id: project.id,
        trace_id: random_hex(32),
        span_id: span_id,
        parent_span_id: "",
        segment_id: span_id,
        is_segment: Keyword.get(opts, :is_segment, 1),
        transaction_name: name,
        op: "http.server",
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
end
