defmodule Swatter.Conformance.RustSdkTest do
  use Swatter.DataCase, async: false

  @moduletag :conformance
  # первая сборка sentry-крейта долгая
  @moduletag timeout: 600_000

  import Swatter.ConformanceHelpers

  @dir Path.expand("../../../conformance/rust", __DIR__)

  if System.find_executable("cargo") do
    test "официальный sentry (Rust) доставляет ошибку до issue" do
      {project, dsn} = prepare!()
      start_supervised!({Swatter.Pipeline, name: __MODULE__.Pipeline})

      out =
        run!("cargo", ["run", "--quiet"], cd: @dir, env: [{"SWATTER_DSN", dsn}])

      assert out =~ "event sent"

      issue = await_issue!(project.id, "conformance: hello from sentry-rust")
      assert issue.times_seen == 1
    end
  else
    @tag :skip
    test "sentry-rust: cargo не найден в PATH" do
      flunk("unreachable")
    end
  end
end
