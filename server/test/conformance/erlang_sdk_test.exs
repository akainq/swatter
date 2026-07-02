defmodule Swatter.Conformance.ErlangSdkTest do
  @moduledoc """
  Erlang: официального Sentry SDK нет (ADR-0001), поэтому проверяем сам
  протокол тонким HTTP-клиентом на встроенных httpc + json (OTP 27+) —
  реализация обещанной ADR-0001 «тонкой обёртки над HTTP».
  """

  use Swatter.DataCase, async: false

  @moduletag :conformance
  @moduletag timeout: 120_000

  import Swatter.ConformanceHelpers

  @script Path.expand("../../../conformance/erlang/send_error.escript", __DIR__)

  if System.find_executable("escript") do
    test "envelope из Erlang (httpc + json) доходит до issue" do
      {project, dsn} = prepare!()
      start_supervised!({Swatter.Pipeline, name: __MODULE__.Pipeline})

      out = run!("escript", [@script], env: [{"SWATTER_DSN", dsn}])
      assert out =~ "event sent"

      issue = await_issue!(project.id, "conformance: hello from erlang")
      assert issue.times_seen == 1
    end
  else
    @tag :skip
    test "erlang: escript не найден в PATH" do
      flunk("unreachable")
    end
  end
end
