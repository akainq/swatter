defmodule Swatter.Conformance.GoSdkTest do
  use Swatter.DataCase, async: false

  @moduletag :conformance
  @moduletag timeout: 300_000

  import Swatter.ConformanceHelpers

  @dir Path.expand("../../../conformance/go", __DIR__)

  if System.find_executable("go") do
    test "официальный sentry-go доставляет ошибку до issue" do
      {project, dsn} = prepare!()
      start_supervised!({Swatter.Pipeline, name: __MODULE__.Pipeline})

      run!("go", ["mod", "tidy"], cd: @dir)
      out = run!("go", ["run", "."], cd: @dir, env: [{"SWATTER_DSN", dsn}])
      assert out =~ "event sent"

      issue = await_issue!(project.id, "conformance: hello from sentry-go")
      assert issue.times_seen == 1
    end
  else
    @tag :skip
    test "sentry-go: go не найден в PATH" do
      flunk("unreachable")
    end
  end
end
