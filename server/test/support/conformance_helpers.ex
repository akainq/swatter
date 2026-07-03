defmodule Swatter.ConformanceHelpers do
  @moduledoc """
  Общий каркас conformance-тестов (ROADMAP M1): подготовка чистого
  состояния, DSN для мини-приложения, запуск внешних команд и ожидание
  issue в PG после пайплайна.
  """

  import Ecto.Query, only: [from: 2]
  import ExUnit.Assertions
  import Swatter.ProjectsFixtures

  alias Swatter.EventsRepo
  alias Swatter.Ingest.Buffer
  alias Swatter.Issues.Issue
  alias Swatter.Repo

  @doc "Чистый буфер/CH + свежий проект. Возвращает {project, dsn}."
  def prepare! do
    Redix.command!(Buffer.conn_name(), ["DEL", Buffer.stream()])
    EventsRepo.query!("TRUNCATE TABLE events")
    EventsRepo.query!("TRUNCATE TABLE spans")
    {project, key} = project_fixture()

    port = Application.get_env(:swatter, SwatterWeb.Endpoint)[:http][:port]
    dsn = "http://#{key.public_key}@127.0.0.1:#{port}/#{project.id}"
    {project, dsn}
  end

  @doc "Запускает команду, падает с выводом при ненулевом статусе."
  def run!(cmd, args, opts \\ []) do
    {out, status} = System.cmd(cmd, args, [stderr_to_stdout: true] ++ opts)
    assert status == 0, "#{cmd} #{Enum.join(args, " ")} failed:\n#{out}"
    out
  end

  @doc "Ждёт появления issue проекта с фрагментом в title."
  def await_issue!(project_id, title_fragment, attempts \\ 60) do
    issue =
      Repo.one(
        from(i in Issue,
          where: i.project_id == ^project_id,
          order_by: [desc: i.id],
          limit: 1
        )
      )

    cond do
      issue && issue.title =~ title_fragment ->
        issue

      attempts > 0 ->
        Process.sleep(250)
        await_issue!(project_id, title_fragment, attempts - 1)

      true ->
        flunk("issue с «#{title_fragment}» не появился (последний: #{inspect(issue)})")
    end
  end
end
