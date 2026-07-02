defmodule Swatter.Conformance.CppSdkTest do
  @moduledoc """
  C++ (sentry-native). Сборка тяжёлая (cmake + компилятор + libcurl,
  FetchContent тянет и собирает SDK), поэтому тест opt-in: выполняется
  только при `SWATTER_CPP_CONFORMANCE=1` и наличии cmake — иначе скип,
  чтобы не вешать обычный прогон и CI. На чистой Linux-машине:

      SWATTER_CPP_CONFORMANCE=1 mix test --only conformance
  """

  use Swatter.DataCase, async: false

  @moduletag :conformance
  # первая сборка sentry-native долгая
  @moduletag timeout: 900_000

  import Swatter.ConformanceHelpers

  @dir Path.expand("../../../conformance/cpp", __DIR__)
  @enabled System.get_env("SWATTER_CPP_CONFORMANCE") == "1" and
             System.find_executable("cmake") != nil

  if @enabled do
    test "официальный sentry-native доставляет событие до issue" do
      {project, dsn} = prepare!()
      start_supervised!({Swatter.Pipeline, name: __MODULE__.Pipeline})

      build = Path.join(@dir, "build")
      run!("cmake", ["-S", @dir, "-B", build])
      run!("cmake", ["--build", build, "--config", "Release"])

      exe =
        [
          Path.join(build, "send_error"),
          Path.join(build, "Release/send_error.exe"),
          Path.join(build, "send_error.exe")
        ]
        |> Enum.find(&File.exists?/1)

      assert exe, "не найден собранный бинарь send_error"

      out = run!(exe, [], env: [{"SWATTER_DSN", dsn}])
      assert out =~ "event sent"

      issue = await_issue!(project.id, "conformance: hello from sentry-native")
      assert issue.times_seen == 1
    end
  else
    @tag :skip
    test "sentry-native: включается через SWATTER_CPP_CONFORMANCE=1 + cmake" do
      flunk("unreachable")
    end
  end
end
