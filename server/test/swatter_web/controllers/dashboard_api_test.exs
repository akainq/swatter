defmodule SwatterWeb.DashboardApiTest do
  # async: false — тесты событий делят таблицу events в ClickHouse
  use SwatterWeb.ConnCase, async: false

  import OpenApiSpex.TestAssertions
  import Swatter.AccountsFixtures
  import Swatter.EventFixtures
  import Swatter.ProjectsFixtures

  alias Swatter.EventsRepo
  alias Swatter.Issues
  alias Swatter.Pipeline.Normalizer

  @received_at ~U[2026-07-02 12:00:00.000000Z]

  setup %{conn: conn} do
    EventsRepo.query!("TRUNCATE TABLE events")
    {project, key} = project_fixture()
    org = Swatter.Repo.get!(Swatter.Projects.Organization, project.organization_id)
    user = member_fixture(org)
    %{conn: log_in_user(conn, user), org: org, project: project, key: key, user: user}
  end

  defp create_issue(project, fingerprint, opts \\ []) do
    times = Keyword.get(opts, :times, 1)
    at = Keyword.get(opts, :at, @received_at)

    overrides = %{
      "fingerprint" => [fingerprint],
      "timestamp" => DateTime.to_unix(at, :millisecond) / 1000
    }

    overrides =
      case Keyword.get(opts, :title) do
        nil -> overrides
        title -> Map.put(overrides, "message", title)
      end

    normalized = Normalizer.normalize(bun_event(overrides), at)

    # позволяет тесту переопределить title/culprit (в bun_event они из exception)
    normalized =
      normalized
      |> maybe_put(:title, Keyword.get(opts, :title))
      |> maybe_put(:culprit, Keyword.get(opts, :culprit))

    Enum.reduce(1..times, nil, fn _, _ ->
      {:ok, issue} = Issues.upsert_from_event(normalized, project.organization_id, project.id)
      issue
    end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp insert_ch_event_env(project, issue, event_id, environment, release) do
    row = %{
      org_id: project.organization_id,
      project_id: project.id,
      issue_id: issue.id,
      event_id: String.pad_trailing(event_id, 32, "0"),
      timestamp: @received_at,
      received_at: @received_at,
      level: "error",
      message: "",
      exception_type: "Error",
      exception_value: "boom",
      culprit: "",
      release: release,
      environment: environment,
      platform: "node",
      sdk_name: "sentry.javascript.bun",
      sdk_version: "10.63.0",
      user_id: "",
      user_email: "",
      user_ip: "",
      tags: %{},
      trace_id: "",
      payload: Jason.encode!(%{})
    }

    {1, _} = EventsRepo.insert_all(Swatter.Events.Event, [row])
    :ok
  end

  defp insert_ch_event(project, issue, event_id, at) do
    payload = bun_event(%{"event_id" => event_id})

    row = %{
      org_id: project.organization_id,
      project_id: project.id,
      issue_id: issue.id,
      event_id: event_id,
      timestamp: at,
      received_at: at,
      level: "error",
      message: "",
      exception_type: "Error",
      exception_value: "boom",
      culprit: "send_error.ts in ?",
      release: "conformance@0.0.1",
      environment: "conformance",
      platform: "node",
      sdk_name: "sentry.javascript.bun",
      sdk_version: "10.63.0",
      user_id: "u-42",
      user_email: "dev@example.com",
      user_ip: "127.0.0.1",
      tags: %{"feature" => "checkout"},
      trace_id: "4541246aa98542e4980c637cd76e4b1a",
      payload: Jason.encode!(payload)
    }

    {1, _} = EventsRepo.insert_all(Swatter.Events.Event, [row])
    :ok
  end

  describe "GET /api/0/organizations" do
    test "только организации пользователя, по схеме", %{conn: conn, org: org} do
      # чужая организация существует, но не видна
      _foreign = org_fixture()

      body = conn |> get("/api/0/organizations") |> json_response(200)

      assert Enum.map(body, & &1["slug"]) == [org.slug]
      api_spec = SwatterWeb.ApiSpec.spec()
      for item <- body, do: assert_schema(item, "Organization", api_spec)
    end
  end

  describe "изоляция организаций" do
    test "чужие проекты и issues неотличимы от несуществующих (404)", %{conn: conn} do
      {foreign_project, _} = project_fixture()

      foreign_org =
        Swatter.Repo.get!(Swatter.Projects.Organization, foreign_project.organization_id)

      foreign_issue = create_issue(foreign_project, "foreign-fp")

      assert conn
             |> get("/api/0/organizations/#{foreign_org.slug}/projects")
             |> json_response(404)

      assert conn
             |> get("/api/0/projects/#{foreign_org.slug}/#{foreign_project.slug}/issues")
             |> json_response(404)

      assert conn |> get("/api/0/issues/#{foreign_issue.id}") |> json_response(404)

      assert conn
             |> put("/api/0/issues/#{foreign_issue.id}", %{status: "resolved"})
             |> json_response(404)

      assert conn
             |> get("/api/0/issues/#{foreign_issue.id}/events/latest")
             |> json_response(404)
    end
  end

  describe "GET /api/0/organizations/:org_slug/projects" do
    test "проекты с DSN", %{conn: conn, org: org, project: project, key: key} do
      body = conn |> get("/api/0/organizations/#{org.slug}/projects") |> json_response(200)

      found = Enum.find(body, &(&1["slug"] == project.slug))
      assert found
      assert found["dsn"] =~ key.public_key
      assert found["dsn"] =~ "/#{project.id}"
    end

    test "404 для неизвестной организации", %{conn: conn} do
      assert conn |> get("/api/0/organizations/nope/projects") |> json_response(404)
    end
  end

  describe "счётчики проектов и переименование" do
    test "список проектов несёт unresolvedIssues и events24h", %{
      conn: conn,
      org: org,
      project: project
    } do
      i1 = create_issue(project, "fp-c1")
      i2 = create_issue(project, "fp-c2")
      {:ok, _} = Issues.update_status(i2, "resolved")

      insert_ch_event(project, i1, String.duplicate("1", 32), DateTime.utc_now())
      insert_ch_event(project, i1, String.duplicate("2", 32), DateTime.utc_now())
      # старое событие не попадает в суточный счётчик
      insert_ch_event(
        project,
        i1,
        String.duplicate("3", 32),
        DateTime.add(DateTime.utc_now(), -172_800, :second)
      )

      body = conn |> get("/api/0/organizations/#{org.slug}/projects") |> json_response(200)
      found = Enum.find(body, &(&1["slug"] == project.slug))

      assert found["unresolvedIssues"] == 1
      assert found["events24h"] == 2
      assert_schema(found, "Project", SwatterWeb.ApiSpec.spec())
    end

    test "PUT переименовывает, slug и DSN не меняются", %{
      conn: conn,
      org: org,
      project: project,
      key: key
    } do
      body =
        conn
        |> put("/api/0/projects/#{org.slug}/#{project.slug}", %{
          name: "Renamed Backend",
          platform: "elixir",
          slug: "hacked-slug"
        })
        |> json_response(200)

      assert body["name"] == "Renamed Backend"
      assert body["platform"] == "elixir"
      # slug из тела игнорируется
      assert body["slug"] == project.slug
      assert body["dsn"] =~ key.public_key
    end

    test "PUT: пустое имя → 400, чужой проект → 404", %{conn: conn, org: org, project: project} do
      assert conn
             |> put("/api/0/projects/#{org.slug}/#{project.slug}", %{name: ""})
             |> json_response(400)

      {foreign, _} = project_fixture()

      foreign_org =
        Swatter.Repo.get!(Swatter.Projects.Organization, foreign.organization_id)

      assert conn
             |> put("/api/0/projects/#{foreign_org.slug}/#{foreign.slug}", %{name: "X"})
             |> json_response(404)
    end

    test "зарезервированный slug при создании → 400", %{conn: conn, org: org} do
      assert conn
             |> post("/api/0/organizations/#{org.slug}/projects", %{
               name: "Bad",
               slug: "projects"
             })
             |> json_response(400)
    end
  end

  describe "POST /api/0/organizations/:org_slug/projects" do
    test "создаёт проект сразу с DSN", %{conn: conn, org: org} do
      body =
        conn
        |> post("/api/0/organizations/#{org.slug}/projects", %{name: "Backend", slug: "backend"})
        |> json_response(201)

      assert body["slug"] == "backend"
      assert body["dsn"] =~ ~r"^http://[0-9a-f]{32}@"

      assert_schema(body, "Project", SwatterWeb.ApiSpec.spec())
    end

    test "невалидный slug → 400", %{conn: conn, org: org} do
      body =
        conn
        |> post("/api/0/organizations/#{org.slug}/projects", %{name: "X", slug: "Не Слаг"})
        |> json_response(400)

      assert body["detail"] =~ "slug"
    end

    test "дубликат slug в организации → 400", %{conn: conn, org: org, project: project} do
      assert conn
             |> post("/api/0/organizations/#{org.slug}/projects", %{
               name: "Dup",
               slug: project.slug
             })
             |> json_response(400)
    end

    test "чужая организация → 404", %{conn: conn} do
      foreign = org_fixture()

      assert conn
             |> post("/api/0/organizations/#{foreign.slug}/projects", %{name: "X", slug: "x"})
             |> json_response(404)
    end
  end

  describe "GET /api/0/projects/:org/:project/issues" do
    test "по умолчанию unresolved, новые сверху", %{conn: conn, org: org, project: project} do
      i1 = create_issue(project, "fp-1", at: ~U[2026-07-02 10:00:00.000000Z])
      _i2 = create_issue(project, "fp-2", at: ~U[2026-07-02 11:00:00.000000Z])
      i3 = create_issue(project, "fp-3", at: ~U[2026-07-02 12:00:00.000000Z])

      {:ok, _} = Issues.update_status(i1, "resolved")

      body =
        conn
        |> get("/api/0/projects/#{org.slug}/#{project.slug}/issues")
        |> json_response(200)

      assert Enum.map(body, & &1["id"]) |> length() == 2
      assert hd(body)["id"] == to_string(i3.id)
      refute Enum.any?(body, &(&1["status"] == "resolved"))

      api_spec = SwatterWeb.ApiSpec.spec()
      for item <- body, do: assert_schema(item, "Issue", api_spec)
    end

    test "status=all и status=resolved", %{conn: conn, org: org, project: project} do
      i1 = create_issue(project, "fp-1")
      _i2 = create_issue(project, "fp-2")
      {:ok, _} = Issues.update_status(i1, "resolved")

      base = "/api/0/projects/#{org.slug}/#{project.slug}/issues"

      all = conn |> get(base <> "?status=all") |> json_response(200)
      assert length(all) == 2

      resolved = conn |> get(base <> "?status=resolved") |> json_response(200)
      assert [%{"status" => "resolved"}] = resolved
    end

    test "sort=freq — самые частые сверху", %{conn: conn, org: org, project: project} do
      _rare = create_issue(project, "fp-rare", times: 1)
      frequent = create_issue(project, "fp-frequent", times: 5)

      body =
        conn
        |> get("/api/0/projects/#{org.slug}/#{project.slug}/issues?sort=freq")
        |> json_response(200)

      assert hd(body)["id"] == to_string(frequent.id)
      assert hd(body)["count"] == 5
    end

    test "keyset-пагинация через Link-заголовок", %{conn: conn, org: org, project: project} do
      for {fp, hour} <- [{"fp-a", 9}, {"fp-b", 10}, {"fp-c", 11}] do
        at = DateTime.new!(~D[2026-07-02], Time.new!(hour, 0, 0), "Etc/UTC")
        create_issue(project, fp, at: at)
      end

      base = "/api/0/projects/#{org.slug}/#{project.slug}/issues"

      first_conn = get(conn, base <> "?limit=2")
      page1 = json_response(first_conn, 200)
      assert length(page1) == 2

      [link] = get_resp_header(first_conn, "link")
      assert link =~ ~s(rel="next")
      [_, cursor] = Regex.run(~r/cursor="([^"]+)"/, link)

      page2 = conn |> get(base <> "?limit=2&cursor=#{cursor}") |> json_response(200)
      assert length(page2) == 1
      assert MapSet.disjoint?(MapSet.new(page1, & &1["id"]), MapSet.new(page2, & &1["id"]))
    end

    test "битый курсор → 400, чужой проект → 404", %{conn: conn, org: org, project: project} do
      base = "/api/0/projects/#{org.slug}/#{project.slug}/issues"
      assert conn |> get(base <> "?cursor=!!!") |> json_response(400)
      assert conn |> get("/api/0/projects/#{org.slug}/nope/issues") |> json_response(404)
    end

    test "поиск по заголовку и culprit", %{conn: conn, org: org, project: project} do
      create_issue(project, "fp-timeout", title: "TimeoutError: db slow", culprit: "db.ex")
      create_issue(project, "fp-nil", title: "ArgumentError: nil", culprit: "worker.ex")

      base = "/api/0/projects/#{org.slug}/#{project.slug}/issues"

      by_title = conn |> get(base <> "?query=timeout") |> json_response(200)
      assert [%{"title" => "TimeoutError: db slow"}] = by_title

      by_culprit = conn |> get(base <> "?query=worker") |> json_response(200)
      assert [%{"culprit" => "worker.ex"}] = by_culprit

      # спецсимволы LIKE экранируются, не роняют запрос
      assert conn |> get(base <> "?query=50%25") |> json_response(200) == []
    end

    test "фильтр по environment/release через CH", %{
      conn: conn,
      org: org,
      project: project
    } do
      prod = create_issue(project, "fp-prod")
      staging = create_issue(project, "fp-staging")

      insert_ch_event_env(project, prod, "prod-1", "production", "v1.0")
      insert_ch_event_env(project, staging, "stg-1", "staging", "v1.1")

      base = "/api/0/projects/#{org.slug}/#{project.slug}/issues?status=all"

      by_env = conn |> get(base <> "&environment=production") |> json_response(200)
      assert [%{"id" => id}] = by_env
      assert id == to_string(prod.id)

      by_release = conn |> get(base <> "&release=v1.1") |> json_response(200)
      assert [%{"id" => id}] = by_release
      assert id == to_string(staging.id)

      # несуществующее окружение → пусто
      assert conn |> get(base <> "&environment=nope") |> json_response(200) == []
    end

    test "endpoint значений фильтров", %{conn: conn, org: org, project: project} do
      issue = create_issue(project, "fp-fv")
      insert_ch_event_env(project, issue, "e1", "production", "v2.0")
      insert_ch_event_env(project, issue, "e2", "staging", "v2.1")

      body =
        conn
        |> get("/api/0/projects/#{org.slug}/#{project.slug}/filters")
        |> json_response(200)

      assert "production" in body["environments"]
      assert "staging" in body["environments"]
      assert "v2.0" in body["releases"]
      assert_schema(body, "FilterValues", SwatterWeb.ApiSpec.spec())
    end
  end

  describe "artifact upload" do
    defp upload(content, filename \\ "app.js.map") do
      path = Path.join(System.tmp_dir!(), "swatter-test-#{System.unique_integer([:positive])}")
      File.write!(path, content)
      on_exit(fn -> File.rm(path) end)
      %Plug.Upload{path: path, filename: filename, content_type: "application/json"}
    end

    test "multipart-загрузка sourcemap, затем доступна символикатору", %{
      conn: conn,
      org: org,
      project: project
    } do
      content = ~s({"version":3,"sources":["a.ts"],"mappings":"AAAA"})

      body =
        conn
        |> post("/api/0/projects/#{org.slug}/#{project.slug}/artifacts", %{
          "file" => upload(content),
          "debug_id" => "DEAD-BEEF",
          "type" => "source_map",
          "name" => "app.js.map"
        })
        |> json_response(201)

      assert body["debugId"] == "deadbeef"
      assert body["type"] == "source_map"
      assert body["size"] == byte_size(content)
      assert_schema(body, "Artifact", SwatterWeb.ApiSpec.spec())

      assert Swatter.Artifacts.fetch_source_map(project.id, "deadbeef") == content
    end

    test "без обязательных полей → 400", %{conn: conn, org: org, project: project} do
      base = "/api/0/projects/#{org.slug}/#{project.slug}/artifacts"

      assert conn
             |> post(base, %{"debug_id" => "x", "type" => "source_map"})
             |> json_response(400)

      assert conn
             |> post(base, %{"file" => upload("x"), "type" => "source_map"})
             |> json_response(400)

      assert conn
             |> post(base, %{"file" => upload("x"), "debug_id" => "x", "type" => "bogus"})
             |> json_response(400)
    end

    test "чужой проект → 404", %{conn: conn} do
      {foreign, _} = project_fixture()

      foreign_org =
        Swatter.Repo.get!(Swatter.Projects.Organization, foreign.organization_id)

      assert conn
             |> post("/api/0/projects/#{foreign_org.slug}/#{foreign.slug}/artifacts", %{
               "file" => upload("x"),
               "debug_id" => "x",
               "type" => "source_map"
             })
             |> json_response(404)
    end
  end

  describe "releases API" do
    test "список релизов со счётчиком новых issues и деталка", %{
      conn: conn,
      org: org,
      project: project
    } do
      r1 = Swatter.Releases.get_or_create(project.id, "v1.0", @received_at)

      for fp <- ["ra", "rb"] do
        n =
          Swatter.Pipeline.Normalizer.normalize(
            bun_event(%{"release" => "v1.0", "fingerprint" => [fp]}),
            @received_at
          )

        {:ok, _} = Issues.upsert_from_event(n, project.organization_id, project.id, r1)
      end

      base = "/api/0/projects/#{org.slug}/#{project.slug}/releases"

      list = conn |> get(base) |> json_response(200)
      assert [%{"version" => "v1.0", "newIssues" => 2, "ordinal" => 1}] = list
      for item <- list, do: assert_schema(item, "Release", SwatterWeb.ApiSpec.spec())

      detail = conn |> get(base <> "/v1.0") |> json_response(200)
      assert detail["version"] == "v1.0"
      assert length(detail["newIssues"]) == 2
      assert_schema(detail, "ReleaseDetail", SwatterWeb.ApiSpec.spec())
    end

    test "неизвестный релиз → 404, чужой проект → 404", %{conn: conn, org: org, project: project} do
      assert conn
             |> get("/api/0/projects/#{org.slug}/#{project.slug}/releases/nope")
             |> json_response(404)

      {foreign, _} = project_fixture()

      foreign_org =
        Swatter.Repo.get!(Swatter.Projects.Organization, foreign.organization_id)

      assert conn
             |> get("/api/0/projects/#{foreign_org.slug}/#{foreign.slug}/releases")
             |> json_response(404)
    end

    test "issue-сериализация несёт regressed", %{conn: conn, project: project} do
      issue = create_issue(project, "fp-reg")
      {:ok, _} = issue |> Ecto.Changeset.change(regressed: true) |> Swatter.Repo.update()

      body = conn |> get("/api/0/issues/#{issue.id}") |> json_response(200)
      assert body["regressed"] == true
    end
  end

  describe "GET/PUT /api/0/issues/:id" do
    test "деталка с проектом", %{conn: conn, project: project} do
      issue = create_issue(project, "fp-detail")

      body = conn |> get("/api/0/issues/#{issue.id}") |> json_response(200)
      assert body["id"] == to_string(issue.id)
      assert body["project"]["slug"] == project.slug

      assert_schema(body, "Issue", SwatterWeb.ApiSpec.spec())
    end

    test "404 для несуществующего", %{conn: conn} do
      assert conn |> get("/api/0/issues/999999999") |> json_response(404)
      assert conn |> get("/api/0/issues/abc") |> json_response(404)
    end

    test "resolve и unresolve", %{conn: conn, project: project} do
      issue = create_issue(project, "fp-status")

      body = conn |> put("/api/0/issues/#{issue.id}", %{status: "resolved"}) |> json_response(200)
      assert body["status"] == "resolved"

      body =
        conn |> put("/api/0/issues/#{issue.id}", %{status: "unresolved"}) |> json_response(200)

      assert body["status"] == "unresolved"
    end

    test "невалидный статус → 400", %{conn: conn, project: project} do
      issue = create_issue(project, "fp-bad-status")
      assert conn |> put("/api/0/issues/#{issue.id}", %{status: "wat"}) |> json_response(400)
    end
  end

  describe "события issue" do
    test "latest возвращает последнее с exception из payload", %{conn: conn, project: project} do
      issue = create_issue(project, "fp-events")
      insert_ch_event(project, issue, String.duplicate("a", 32), ~U[2026-07-02 10:00:00.000000Z])
      insert_ch_event(project, issue, String.duplicate("b", 32), ~U[2026-07-02 11:00:00.000000Z])

      body = conn |> get("/api/0/issues/#{issue.id}/events/latest") |> json_response(200)

      assert body["eventId"] == String.duplicate("b", 32)
      assert [%{"type" => "Error"} | _] = body["exception"]["values"]
      assert %{"key" => "feature", "value" => "checkout"} in body["tags"]

      assert_schema(body, "Event", SwatterWeb.ApiSpec.spec())
    end

    test "список с пагинацией", %{conn: conn, project: project} do
      issue = create_issue(project, "fp-event-list")
      insert_ch_event(project, issue, String.duplicate("a", 32), ~U[2026-07-02 10:00:00.000000Z])
      insert_ch_event(project, issue, String.duplicate("b", 32), ~U[2026-07-02 11:00:00.000000Z])

      first_conn = get(conn, "/api/0/issues/#{issue.id}/events?limit=1")
      page1 = json_response(first_conn, 200)
      assert [%{"eventId" => first_id}] = page1
      assert first_id == String.duplicate("b", 32)

      [link] = get_resp_header(first_conn, "link")
      [_, cursor] = Regex.run(~r/cursor="([^"]+)"/, link)

      page2 =
        conn
        |> get("/api/0/issues/#{issue.id}/events?limit=1&cursor=#{cursor}")
        |> json_response(200)

      assert [%{"eventId" => second_id}] = page2
      assert second_id == String.duplicate("a", 32)
    end

    test "404 без issue, 404 latest без событий", %{conn: conn, project: project} do
      assert conn |> get("/api/0/issues/999999999/events/latest") |> json_response(404)

      empty_issue = create_issue(project, "fp-no-events")
      assert conn |> get("/api/0/issues/#{empty_issue.id}/events/latest") |> json_response(404)
    end
  end

  test "GET /api/0/openapi.json отдаёт валидную спеку", %{conn: conn} do
    body = conn |> get("/api/0/openapi.json") |> json_response(200)
    assert body["openapi"]
    assert body["paths"]["/api/0/issues/{issue_id}"]["get"]
    assert body["components"]["schemas"]["Issue"]
  end
end
