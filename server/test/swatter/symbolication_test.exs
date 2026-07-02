defmodule Swatter.SymbolicationTest do
  use Swatter.DataCase, async: false

  import Swatter.ProjectsFixtures

  alias Swatter.{Artifacts, Symbolication}
  alias Swatter.Symbolication.Cache

  setup do
    Cache.clear()
    {project, _} = project_fixture()
    %{project: project}
  end

  # карта: generated (1,1) → src/app.ts:3 name handleClick, с контекстом
  defp source_map do
    Jason.encode!(%{
      "version" => 3,
      "sources" => ["src/app.ts"],
      "names" => ["handleClick"],
      "sourcesContent" => ["import x\n\nfunction handleClick() { throw new Error() }\n"],
      "mappings" => "AAEAA"
    })
  end

  defp event_with_frame(debug_id) do
    %{
      "exception" => %{
        "values" => [
          %{
            "type" => "Error",
            "value" => "boom",
            "stacktrace" => %{
              "frames" => [
                %{
                  "filename" => "app.min.js",
                  "abs_path" => "https://cdn.example.com/app.min.js",
                  "function" => "a",
                  "lineno" => 1,
                  "colno" => 1,
                  "in_app" => true
                }
              ]
            }
          }
        ]
      },
      "debug_meta" => %{
        "images" => [
          %{
            "type" => "sourcemap",
            "code_file" => "https://cdn.example.com/app.min.js",
            "debug_id" => debug_id
          }
        ]
      }
    }
  end

  test "минифицированный фрейм разворачивается по debug_id", %{project: project} do
    debug_id = "1111222233334444aaaabbbbccccdddd"
    {:ok, _} = Artifacts.put(project.id, debug_id, "source_map", source_map())

    event = Symbolication.symbolicate(event_with_frame(debug_id), project.id)

    [frame] = get_in(event, ["exception", "values", Access.at(0), "stacktrace", "frames"])
    assert frame["filename"] == "src/app.ts"
    assert frame["lineno"] == 3
    assert frame["function"] == "handleClick"
    assert frame["context_line"] =~ "handleClick"
    assert frame["data"]["symbolicated"] == true
  end

  test "без загруженной карты фрейм остаётся минифицированным", %{project: project} do
    event = Symbolication.symbolicate(event_with_frame("no-map-uploaded"), project.id)

    [frame] = get_in(event, ["exception", "values", Access.at(0), "stacktrace", "frames"])
    assert frame["filename"] == "app.min.js"
    assert frame["lineno"] == 1
    refute frame["data"]
  end

  test "событие без debug_meta возвращается как есть", %{project: project} do
    event = %{"exception" => %{"values" => [%{"type" => "Error"}]}}
    assert Symbolication.symbolicate(event, project.id) == event
  end

  test "кэш переиспользуется между вызовами", %{project: project} do
    debug_id = "cachecachecachecachecachecacheab"
    {:ok, _} = Artifacts.put(project.id, debug_id, "source_map", source_map())

    e1 = Symbolication.symbolicate(event_with_frame(debug_id), project.id)

    # удаляем артефакт: если бы читали из БД, второй вызов не символиковал бы
    Swatter.Repo.delete_all(Swatter.Artifacts.ArtifactBundle)
    e2 = Symbolication.symbolicate(event_with_frame(debug_id), project.id)

    frame1 = get_in(e1, ["exception", "values", Access.at(0), "stacktrace", "frames"]) |> hd()
    frame2 = get_in(e2, ["exception", "values", Access.at(0), "stacktrace", "frames"]) |> hd()
    assert frame1["filename"] == "src/app.ts"
    assert frame2["filename"] == "src/app.ts"
  end
end
