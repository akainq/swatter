defmodule Swatter.PipelineTest do
  @moduledoc """
  Интеграция пайплайна: буфер (Redis) → Broadway → issue в PG + строка в CH.
  async: false — shared sandbox (процессы Broadway ходят в Repo) и общий
  Redis-стрим/таблица events.
  """

  use Swatter.DataCase, async: false

  import Swatter.EventFixtures
  import Swatter.ProjectsFixtures

  alias Swatter.Events.Event
  alias Swatter.EventsRepo
  alias Swatter.Ingest.Buffer
  alias Swatter.Issues.Issue

  setup do
    Redix.command!(Buffer.conn_name(), ["DEL", Buffer.stream()])
    EventsRepo.query!("TRUNCATE TABLE events")
    start_supervised!({Swatter.Pipeline, name: __MODULE__.Pipeline})
    :ok
  end

  test "событие из буфера становится issue в PG и строкой в ClickHouse" do
    {project, key} = project_fixture()
    event = bun_event()

    :ok = Buffer.enqueue(project.id, key.id, envelope_with_event(event), %{})

    issue = wait_until(fn -> Repo.get_by(Issue, project_id: project.id) end)
    assert issue.times_seen == 1
    assert issue.title == "Error: conformance: hello from @sentry/bun"
    assert issue.culprit == "send_error.ts in ?"
    assert issue.level == "error"

    [row] = wait_until(fn -> ch_rows(project.id) end)
    assert row.issue_id == issue.id
    assert row.org_id == project.organization_id
    assert row.event_id == event["event_id"]
    assert row.environment == "conformance"
    assert row.release == "conformance@0.0.1"
    assert row.tags["feature"] == "checkout"
    assert row.trace_id == "4541246aa98542e4980c637cd76e4b1a"
    assert Jason.decode!(row.payload)["platform"] == "node"
  end

  test "повторная ошибка группируется в тот же issue, события копятся в CH" do
    {project, key} = project_fixture()

    :ok = Buffer.enqueue(project.id, key.id, envelope_with_event(bun_event()), %{})

    second = bun_event(%{"event_id" => "ffffffffffffffffffffffffffffffff"})
    :ok = Buffer.enqueue(project.id, key.id, envelope_with_event(second), %{})

    issue =
      wait_until(fn ->
        case Repo.get_by(Issue, project_id: project.id) do
          %Issue{times_seen: 2} = issue -> issue
          _ -> nil
        end
      end)

    assert issue.times_seen == 2
    assert [_only_one] = Repo.all(from i in Issue, where: i.project_id == ^project.id)

    rows =
      wait_until(fn ->
        case ch_rows(project.id) do
          rows when is_list(rows) and length(rows) == 2 -> rows
          _ -> nil
        end
      end)

    assert Enum.map(rows, & &1.issue_id) == [issue.id, issue.id]
  end

  test "session-only envelope и мусор дропаются, не ломая пайплайн" do
    {project, key} = project_fixture()

    session_envelope = ~s({}\n{"type":"session"}\n{"sid":"s1","status":"ok"}\n)
    :ok = Buffer.enqueue(project.id, key.id, session_envelope, %{})
    :ok = Buffer.enqueue(project.id, key.id, "totally not an envelope", %{})
    :ok = Buffer.enqueue(project.id, key.id, envelope_with_event(bun_event()), %{})

    issue = wait_until(fn -> Repo.get_by(Issue, project_id: project.id) end)
    assert issue.times_seen == 1

    assert [_only_event_row] = wait_until(fn -> ch_rows(project.id) end)
  end

  defp ch_rows(project_id) do
    case EventsRepo.all(from e in Event, where: e.project_id == ^project_id) do
      [] -> nil
      rows -> rows
    end
  end

  defp wait_until(fun, attempts \\ 40) do
    case fun.() do
      nil ->
        if attempts > 0 do
          Process.sleep(250)
          wait_until(fun, attempts - 1)
        else
          flunk("условие не выполнилось за отведённое время")
        end

      result ->
        result
    end
  end
end
