defmodule Swatter.Conformance.ElixirSdkTest do
  use Swatter.DataCase, async: false

  @moduletag :conformance
  @moduletag timeout: 300_000

  import Swatter.ConformanceHelpers

  @dir Path.expand("../../../conformance/elixir", __DIR__)

  test "официальный sentry-elixir доставляет событие до issue" do
    {project, dsn} = prepare!()
    start_supervised!({Swatter.Pipeline, name: __MODULE__.Pipeline})

    env = [{"SWATTER_DSN", dsn}, {"MIX_ENV", "prod"}]
    run!("mix", ["deps.get"], cd: @dir, env: env)
    out = run!("mix", ["run", "send_error.exs"], cd: @dir, env: env)
    assert out =~ "event sent"

    # message-событие (без exception) — проверяет message-ветку группировки
    issue = await_issue!(project.id, "conformance: hello from sentry-elixir")
    assert issue.times_seen == 1
  end
end
