defmodule SwatterWeb.IngestControllerTest do
  # async: false — тесты делят Redis-стрим
  use SwatterWeb.ConnCase, async: false

  import Swatter.ProjectsFixtures

  alias Swatter.Ingest.Buffer
  alias Swatter.Ingest.Envelope

  setup %{conn: conn} do
    Redix.command!(Buffer.conn_name(), ["DEL", Buffer.stream()])
    clear_rate_limits()
    {project, key} = project_fixture()
    %{conn: conn, project: project, key: key}
  end

  defp clear_rate_limits do
    case Redix.command!(Buffer.conn_name(), ["KEYS", "swatter:rl:*"]) do
      [] -> :ok
      keys -> Redix.command!(Buffer.conn_name(), ["DEL" | keys])
    end
  end

  defp set_key_limit(key, count, window_seconds) do
    {:ok, key} =
      key
      |> Swatter.Projects.ProjectKey.changeset(%{
        rate_limit_count: count,
        rate_limit_window_seconds: window_seconds
      })
      |> Swatter.Repo.update()

    key
  end

  defp envelope_body(opts \\ []) do
    header =
      case Keyword.get(opts, :event_id) do
        nil -> %{}
        id -> %{"event_id" => id, "sent_at" => "2026-07-02T12:00:00Z"}
      end

    item_type = Keyword.get(opts, :item_type, "event")
    item = Jason.encode!(%{"message" => "boom"})

    Jason.encode!(header) <>
      "\n" <>
      Jason.encode!(%{"type" => item_type, "length" => byte_size(item)}) <>
      "\n" <> item <> "\n"
  end

  defp post_envelope(conn, project_id, body, opts \\ []) do
    auth = Keyword.get(opts, :auth)
    query = Keyword.get(opts, :query, "")

    conn =
      conn
      |> put_req_header("content-type", "application/x-sentry-envelope")
      |> then(fn c -> if auth, do: put_req_header(c, "x-sentry-auth", auth), else: c end)
      |> then(fn c ->
        Enum.reduce(Keyword.get(opts, :headers, []), c, fn {k, v}, acc ->
          put_req_header(acc, k, v)
        end)
      end)

    post(conn, "/api/#{project_id}/envelope#{query}", body)
  end

  defp auth_header(key), do: "Sentry sentry_version=7, sentry_key=#{key.public_key}"

  defp stream_entries do
    Buffer.conn_name()
    |> Redix.command!(["XRANGE", Buffer.stream(), "-", "+"])
    |> Enum.map(fn [_id, fields] ->
      fields |> Enum.chunk_every(2) |> Map.new(fn [k, v] -> {k, v} end)
    end)
  end

  describe "успешный приём" do
    test "валидный envelope попадает в буфер, ответ — event_id", %{
      conn: conn,
      project: project,
      key: key
    } do
      event_id = "0123456789abcdef0123456789abcdef"
      body = envelope_body(event_id: event_id)

      conn = post_envelope(conn, project.id, body, auth: auth_header(key))

      assert %{"id" => ^event_id} = json_response(conn, 200)

      assert [entry] = stream_entries()
      assert entry["project_id"] == Integer.to_string(project.id)
      assert entry["key_id"] == Integer.to_string(key.id)
      assert entry["payload"] == body
      assert entry["sent_at"] == "2026-07-02T12:00:00Z"
    end

    test "gzip-тело распаковывается до буфера", %{conn: conn, project: project, key: key} do
      body = envelope_body(event_id: "aaaabbbbccccddddaaaabbbbccccdddd")

      conn =
        post_envelope(conn, project.id, :zlib.gzip(body),
          auth: auth_header(key),
          headers: [{"content-encoding", "gzip"}]
        )

      assert %{"id" => _} = json_response(conn, 200)
      assert [entry] = stream_entries()
      assert entry["payload"] == body
    end

    test "аутентификация через ?sentry_key=", %{conn: conn, project: project, key: key} do
      conn =
        post_envelope(conn, project.id, envelope_body(), query: "?sentry_key=#{key.public_key}")

      assert %{"id" => _} = json_response(conn, 200)
      assert [_entry] = stream_entries()
    end

    test "envelope без event_id получает сгенерированный id", %{
      conn: conn,
      project: project,
      key: key
    } do
      conn = post_envelope(conn, project.id, envelope_body(), auth: auth_header(key))
      assert %{"id" => id} = json_response(conn, 200)
      assert id =~ ~r/^[0-9a-f]{32}$/
    end

    test "неизвестные типы items не отклоняются (forward compat)", %{
      conn: conn,
      project: project,
      key: key
    } do
      body = envelope_body(item_type: "hologram_from_2030")
      conn = post_envelope(conn, project.id, body, auth: auth_header(key))

      assert %{"id" => _} = json_response(conn, 200)
      assert [entry] = stream_entries()
      assert entry["payload"] == body
    end

    test "ответ несёт CORS-заголовки", %{conn: conn, project: project, key: key} do
      conn = post_envelope(conn, project.id, envelope_body(), auth: auth_header(key))
      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
    end

    test "OPTIONS preflight → 204 с CORS", %{conn: conn, project: project} do
      conn = options(conn, "/api/#{project.id}/envelope")
      assert response(conn, 204)
      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
    end
  end

  describe "отказы аутентификации (все — 401)" do
    test "без аутентификации", %{conn: conn, project: project} do
      conn = post_envelope(conn, project.id, envelope_body())
      assert %{"detail" => _} = json_response(conn, 401)
      assert stream_entries() == []
    end

    test "несуществующий ключ", %{conn: conn, project: project} do
      auth = "Sentry sentry_key=#{String.duplicate("0", 32)}"
      conn = post_envelope(conn, project.id, envelope_body(), auth: auth)
      assert json_response(conn, 401)
    end

    test "ключ чужого проекта", %{conn: conn, key: key} do
      {other_project, _} = project_fixture()
      conn = post_envelope(conn, other_project.id, envelope_body(), auth: auth_header(key))
      assert json_response(conn, 401)
    end

    test "нечисловой project_id в пути", %{conn: conn, key: key} do
      conn = post_envelope(conn, "abc", envelope_body(), auth: auth_header(key))
      assert json_response(conn, 401)
    end
  end

  describe "rate limiting (ADR-0009)" do
    test "превышение per-key лимита → 429 с заголовками Sentry", %{
      conn: conn,
      project: project,
      key: key
    } do
      key = set_key_limit(key, 2, 60)

      for _ <- 1..2 do
        assert conn
               |> post_envelope(project.id, envelope_body(), auth: auth_header(key))
               |> json_response(200)
      end

      limited = post_envelope(conn, project.id, envelope_body(), auth: auth_header(key))
      assert json_response(limited, 429)

      [retry_after] = get_resp_header(limited, "retry-after")
      assert String.to_integer(retry_after) in 1..60
      assert get_resp_header(limited, "x-sentry-rate-limits") == ["#{retry_after}::key"]

      # в буфер попали только первые два
      assert length(stream_entries()) == 2
    end

    test "после окна приём восстанавливается", %{conn: conn, project: project, key: key} do
      key = set_key_limit(key, 1, 1)

      assert conn
             |> post_envelope(project.id, envelope_body(), auth: auth_header(key))
             |> json_response(200)

      assert conn
             |> post_envelope(project.id, envelope_body(), auth: auth_header(key))
             |> json_response(429)

      Process.sleep(1100)

      assert conn
             |> post_envelope(project.id, envelope_body(), auth: auth_header(key))
             |> json_response(200)
    end

    test "лимит одного ключа не задевает другой проект", %{
      conn: conn,
      project: project,
      key: key
    } do
      key = set_key_limit(key, 1, 60)
      {other_project, other_key} = project_fixture()

      assert conn
             |> post_envelope(project.id, envelope_body(), auth: auth_header(key))
             |> json_response(200)

      assert conn
             |> post_envelope(project.id, envelope_body(), auth: auth_header(key))
             |> json_response(429)

      assert conn
             |> post_envelope(other_project.id, envelope_body(), auth: auth_header(other_key))
             |> json_response(200)
    end

    test "лимит срабатывает до чтения тела (429, а не 413)", %{
      conn: conn,
      project: project,
      key: key
    } do
      key = set_key_limit(key, 1, 60)

      assert conn
             |> post_envelope(project.id, envelope_body(), auth: auth_header(key))
             |> json_response(200)

      oversized = :binary.copy("a", 1_500_000)
      conn = post_envelope(conn, project.id, oversized, auth: auth_header(key))
      assert json_response(conn, 429)
    end
  end

  describe "legacy /store/" do
    defp post_store(conn, project_id, body, opts) do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> then(fn c ->
          case Keyword.get(opts, :auth) do
            nil -> c
            auth -> put_req_header(c, "x-sentry-auth", auth)
          end
        end)
        |> then(fn c ->
          Enum.reduce(Keyword.get(opts, :headers, []), c, fn {k, v}, acc ->
            put_req_header(acc, k, v)
          end)
        end)

      post(conn, "/api/#{project_id}/store", body)
    end

    test "голое событие упаковывается в envelope и попадает в буфер", %{
      conn: conn,
      project: project,
      key: key
    } do
      event_id = "11112222333344445555666677778888"
      event_json = Jason.encode!(%{"event_id" => event_id, "message" => "legacy boom"})

      conn = post_store(conn, project.id, event_json, auth: auth_header(key))
      assert %{"id" => ^event_id} = json_response(conn, 200)

      assert [entry] = stream_entries()
      assert {:ok, header, [{item_header, payload}]} = Envelope.parse(entry["payload"])
      assert header["event_id"] == event_id
      assert item_header["type"] == "event"
      assert payload == event_json
    end

    test "событие без event_id получает сгенерированный", %{
      conn: conn,
      project: project,
      key: key
    } do
      conn = post_store(conn, project.id, ~s({"message":"no id"}), auth: auth_header(key))
      assert %{"id" => id} = json_response(conn, 200)
      assert id =~ ~r/^[0-9a-f]{32}$/
    end

    test "gzip-тело принимается", %{conn: conn, project: project, key: key} do
      event_json = Jason.encode!(%{"message" => "gz"})

      conn =
        post_store(conn, project.id, :zlib.gzip(event_json),
          auth: auth_header(key),
          headers: [{"content-encoding", "gzip"}]
        )

      assert %{"id" => _} = json_response(conn, 200)
    end

    test "мусор → 400, без auth → 401, лимит общий с envelope", %{
      conn: conn,
      project: project,
      key: key
    } do
      assert conn
             |> post_store(project.id, "not json", auth: auth_header(key))
             |> json_response(400)

      assert conn |> post_store(project.id, "{}", []) |> json_response(401)

      # 400-запрос выше уже потратил единицу лимита (проверка идёт до тела) —
      # начинаем окно заново
      clear_rate_limits()
      key = set_key_limit(key, 1, 60)
      assert conn |> post_store(project.id, "{}", auth: auth_header(key)) |> json_response(200)

      # счётчик один на ключ: envelope-запрос тоже упирается в лимит
      assert conn
             |> post_envelope(project.id, envelope_body(), auth: auth_header(key))
             |> json_response(429)
    end
  end

  describe "отказы по телу запроса" do
    test "мусор вместо envelope → 400", %{conn: conn, project: project, key: key} do
      conn = post_envelope(conn, project.id, "not an envelope", auth: auth_header(key))
      assert json_response(conn, 400)
      assert stream_entries() == []
    end

    test "битый gzip → 400", %{conn: conn, project: project, key: key} do
      conn =
        post_envelope(conn, project.id, <<0x1F, 0x8B, 9, 9, 9>>,
          auth: auth_header(key),
          headers: [{"content-encoding", "gzip"}]
        )

      assert json_response(conn, 400)
    end

    test "тело больше лимита → 413", %{conn: conn, project: project, key: key} do
      # test-конфиг: max_compressed_bytes = 1MB
      body = :binary.copy("a", 1_500_000)
      conn = post_envelope(conn, project.id, body, auth: auth_header(key))
      assert json_response(conn, 413)
    end

    test "decompression-бомба → 413", %{conn: conn, project: project, key: key} do
      # test-конфиг: max_envelope_bytes = 5MB; сжатая бомба проходит лимит тела
      bomb = :zlib.gzip(:binary.copy(<<0>>, 6_000_000))

      conn =
        post_envelope(conn, project.id, bomb,
          auth: auth_header(key),
          headers: [{"content-encoding", "gzip"}]
        )

      assert json_response(conn, 413)
      assert stream_entries() == []
    end
  end
end
