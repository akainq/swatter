defmodule Swatter.Conformance.PythonSdkTest do
  use Swatter.DataCase, async: false

  @moduletag :conformance
  @moduletag timeout: 300_000

  import Swatter.ConformanceHelpers

  @dir Path.expand("../../../conformance/python", __DIR__)

  # "python3" первым: на Windows голый "python" может быть заглушкой
  # Microsoft Store (exit 49), а scoop даёт шим python3
  @python System.find_executable("python3") || System.find_executable("python")

  if @python do
    test "официальный sentry-python доставляет ошибку до issue" do
      {project, dsn} = prepare!()
      start_supervised!({Swatter.Pipeline, name: __MODULE__.Pipeline})

      venv_python =
        case :os.type() do
          {:win32, _} -> Path.join(@dir, ".venv/Scripts/python.exe")
          _ -> Path.join(@dir, ".venv/bin/python")
        end

      unless File.exists?(venv_python) do
        run!(@python, ["-m", "venv", ".venv"], cd: @dir)
      end

      run!(venv_python, ["-m", "pip", "install", "--quiet", "sentry-sdk"], cd: @dir)

      out =
        run!(venv_python, ["send_error.py"], cd: @dir, env: [{"SWATTER_DSN", dsn}])

      assert out =~ "event sent"

      issue = await_issue!(project.id, "conformance: hello from sentry-python")
      assert issue.title =~ "ValueError"
      assert issue.times_seen == 1
    end
  else
    @tag :skip
    test "sentry-python: python не найден в PATH" do
      flunk("unreachable")
    end
  end
end
