defmodule Swatter.Conformance.BunSdkTest do
  @moduledoc """
  Conformance (ROADMAP M1): официальный Sentry SDK шлёт событие в Swatter
  по HTTP на живой тестовый endpoint (порт из config/test.exs), зная только
  DSN; пайплайн доводит его до issue в PG и строки в ClickHouse.
  Исключён из обычного прогона: `mix test --only conformance`.
  """

  # async: false → shared sandbox: DB-запросы идут из процессов Bandit/Broadway
  use Swatter.DataCase, async: false

  @moduletag :conformance
  @moduletag timeout: 120_000

  import Swatter.ProjectsFixtures

  alias Swatter.Events.Event
  alias Swatter.EventsRepo
  alias Swatter.Ingest.Buffer
  alias Swatter.Issues.Issue

  @conformance_dir Path.expand("../../../conformance/bun", __DIR__)

  test "реальный @sentry/bun доставляет ошибку после замены DSN" do
    Redix.command!(Buffer.conn_name(), ["DEL", Buffer.stream()])
    EventsRepo.query!("TRUNCATE TABLE events")
    {project, key} = project_fixture()

    port = Application.get_env(:swatter, SwatterWeb.Endpoint)[:http][:port]
    dsn = "http://#{key.public_key}@127.0.0.1:#{port}/#{project.id}"

    {out, status} =
      System.cmd("bun", ["install"], cd: @conformance_dir, stderr_to_stdout: true)

    assert status == 0, "bun install failed:\n" <> out

    {out, status} =
      System.cmd("bun", ["run", "send_error.ts"],
        cd: @conformance_dir,
        env: [{"SWATTER_DSN", dsn}],
        stderr_to_stdout: true
      )

    assert status == 0, "sdk script failed:\n" <> out
    assert out =~ "event sent"

    # SDK шлёт несколько envelope (session от release health + сам event) —
    # ищем среди них тот, что несёт нашу ошибку
    entry = await_entry_with(40, "conformance: hello from @sentry/bun")

    assert entry["project_id"] == Integer.to_string(project.id)
    assert entry["key_id"] == Integer.to_string(key.id)

    # SDK проставляет sent_at в заголовке envelope — приём должен его сохранить
    assert entry["sent_at"] != ""

    # Полный путь: пайплайн (стартуем поверх накопленного backlog) доводит
    # событие до issue в PG и строки в ClickHouse
    start_supervised!({Swatter.Pipeline, name: __MODULE__.Pipeline})

    issue = await(fn -> Repo.get_by(Issue, project_id: project.id) end)
    assert issue.title == "Error: conformance: hello from @sentry/bun"
    assert issue.times_seen == 1
    assert issue.status == "unresolved"
    assert issue.culprit =~ "send_error.ts"

    [row] =
      await(fn ->
        case EventsRepo.all(from e in Event, where: e.project_id == ^project.id) do
          [] -> nil
          rows -> rows
        end
      end)

    assert row.issue_id == issue.id
    assert row.sdk_name == "sentry.javascript.bun"
    assert row.environment == "conformance"
    assert row.release == "conformance@0.0.1"
    assert row.platform == "node"
  end

  defp await(fun, attempts \\ 40) do
    case fun.() do
      nil ->
        if attempts > 0 do
          Process.sleep(250)
          await(fun, attempts - 1)
        else
          flunk("условие не выполнилось за отведённое время")
        end

      result ->
        result
    end
  end

  defp await_entry_with(0, needle) do
    flunk("envelope с «#{needle}» не появился в буфере")
  end

  defp await_entry_with(attempts, needle) do
    found =
      Buffer.conn_name()
      |> Redix.command!(["XRANGE", Buffer.stream(), "-", "+"])
      |> Enum.map(fn [_entry_id, fields] ->
        fields |> Enum.chunk_every(2) |> Map.new(fn [k, v] -> {k, v} end)
      end)
      |> Enum.find(fn entry -> entry["payload"] =~ needle end)

    if found do
      found
    else
      Process.sleep(250)
      await_entry_with(attempts - 1, needle)
    end
  end
end
