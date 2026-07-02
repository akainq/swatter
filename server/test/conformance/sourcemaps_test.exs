defmodule Swatter.Conformance.SourcemapsTest do
  @moduledoc """
  Символикация на реальном инструментарии (M2, ROADMAP): esbuild с
  официальным @sentry/esbuild-plugin собирает минифицированный бандл +
  sourcemap с инжектированным Debug ID; @sentry/node (настоящий node)
  шлёт событие с минифицированным стеком и debug_meta; Swatter
  разворачивает стек по загруженной карте.
  """

  use Swatter.DataCase, async: false

  @moduletag :conformance
  @moduletag timeout: 300_000

  import Swatter.ConformanceHelpers

  alias Swatter.{Artifacts, Events}

  @dir Path.expand("../../../conformance/sourcemaps", __DIR__)

  @node System.find_executable("node")
  @bun System.find_executable("bun")

  if @node && @bun do
    test "минифицированный esbuild-стек символикуется до исходной функции" do
      {project, dsn} = prepare!()

      # 1. сборка реального бандла + карты с инжектом Debug ID (node —
      # bun-сборка даёт иной рантайм debug_id, чем инжектированный)
      run!(@bun, ["install"], cd: @dir)
      run!(@node, ["build.mjs"], cd: @dir)

      bundle = File.read!(Path.join(@dir, "dist/bundle.js"))
      map = File.read!(Path.join(@dir, "dist/bundle.js.map"))

      # 2. debug_id из инжектированного _sentryDebugIds
      [_, debug_id] = Regex.run(~r/_sentryDebugIds\[[^\]]+\]\s*=\s*"([0-9a-f-]{36})"/, bundle)

      # 3. загрузка карты под этим debug_id (через контекст — без HTTP/auth)
      {:ok, _} = Artifacts.put(project.id, debug_id, "source_map", map)

      start_supervised!({Swatter.Pipeline, name: __MODULE__.Pipeline})

      # 4. запуск бандла настоящим node → минифицированное событие с debug_meta
      out = run!(@node, ["dist/bundle.js"], cd: @dir, env: [{"SWATTER_DSN", dsn}])
      assert out =~ "event sent"

      # 5. issue есть (title из exception, не зависит от символикации)
      issue = await_issue!(project.id, "conformance: symbolicated from esbuild bundle")

      # минифицированный фрейм развёрнут: файл из bundle.js → исходник,
      # а строка контекста — оригинальный throw (esbuild-карта не всегда
      # несёт имя функции, поэтому проверяем файл+контекст, не имя)
      event = wait_for(fn -> Events.latest_event(issue.id) end)
      frames = symbolicated_frames(event)

      assert frames != [], "нет символикованных фреймов"

      # все развёрнутые фреймы указывают на исходник, не на bundle.js
      assert Enum.all?(frames, &(&1["filename"] =~ "app.js"))

      # исходный код упоминает нашу функцию (объявление или вызов) —
      # минифицированный стек развёрнут в читаемый
      context = frames |> Enum.map(& &1["context_line"]) |> Enum.join("\n")
      assert context =~ "crashDeepInside"
    end
  else
    @tag :skip
    test "sourcemaps conformance: нужны node и bun" do
      flunk("unreachable")
    end
  end

  defp symbolicated_frames(event) do
    event.payload
    |> Jason.decode!()
    |> get_in(["exception", "values"])
    |> List.last()
    |> get_in(["stacktrace", "frames"])
    |> Enum.filter(fn f -> get_in(f, ["data", "symbolicated"]) == true end)
  end

  defp wait_for(fun, attempts \\ 40) do
    case fun.() do
      nil when attempts > 0 ->
        Process.sleep(250)
        wait_for(fun, attempts - 1)

      nil ->
        flunk("событие не появилось")

      result ->
        result
    end
  end
end
