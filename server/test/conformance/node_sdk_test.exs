defmodule Swatter.Conformance.NodeSdkTest do
  use Swatter.DataCase, async: false

  @moduletag :conformance
  @moduletag timeout: 300_000

  import Swatter.ConformanceHelpers

  @dir Path.expand("../../../conformance/node", __DIR__)

  # настоящий node, а не bun (bun-вариант покрыт @sentry/bun)
  @node System.find_executable("node")

  if @node do
    test "официальный @sentry/node доставляет ошибку до issue" do
      {project, dsn} = prepare!()
      start_supervised!({Swatter.Pipeline, name: __MODULE__.Pipeline})

      # node_modules ставим bun'ом (npm.cmd не запускается через System.cmd
      # на Windows); сам @sentry/node гоняем настоящим node, а не bun
      bun = System.find_executable("bun") || "bun"
      run!(bun, ["install"], cd: @dir)

      out = run!(@node, ["send_error.js"], cd: @dir, env: [{"SWATTER_DSN", dsn}])
      assert out =~ "event sent"

      issue = await_issue!(project.id, "conformance: hello from sentry-node")
      assert issue.times_seen == 1
    end
  else
    @tag :skip
    test "sentry-node: node не найден в PATH" do
      flunk("unreachable")
    end
  end
end
