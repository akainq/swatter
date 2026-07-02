defmodule Swatter.Pipeline.FingerprintTest do
  use ExUnit.Case, async: true

  import Swatter.EventFixtures

  alias Swatter.Pipeline.Fingerprint

  test "детерминирован" do
    event = bun_event()
    assert Fingerprint.compute(event) == Fingerprint.compute(event)
    assert Fingerprint.compute(event) =~ ~r/^[0-9a-f]{64}$/
  end

  test "стабилен к номерам строк и значению исключения (деплой не дробит issue)" do
    event = bun_event()

    moved_line =
      update_in(event, ["exception", "values", Access.at(0), "stacktrace", "frames"], fn frames ->
        Enum.map(frames, &Map.put(&1, "lineno", (&1["lineno"] || 0) + 100))
      end)

    other_value =
      put_in(event, ["exception", "values", Access.at(0), "value"], "id 99999 not found")

    assert Fingerprint.compute(event) == Fingerprint.compute(moved_line)
    assert Fingerprint.compute(event) == Fingerprint.compute(other_value)
  end

  test "разные типы исключений — разные группы" do
    event = bun_event()
    other = put_in(event, ["exception", "values", Access.at(0), "type"], "TypeError")
    refute Fingerprint.compute(event) == Fingerprint.compute(other)
  end

  test "разные in-app фреймы — разные группы" do
    event = bun_event()

    other =
      update_in(event, ["exception", "values", Access.at(0), "stacktrace", "frames"], fn frames ->
        Enum.map(frames, fn
          %{"in_app" => true} = f -> Map.put(f, "function", "somewhereElse")
          f -> f
        end)
      end)

    refute Fingerprint.compute(event) == Fingerprint.compute(other)
  end

  test "изменения не-in-app фреймов не влияют" do
    event = bun_event()

    other =
      update_in(event, ["exception", "values", Access.at(0), "stacktrace", "frames"], fn frames ->
        Enum.map(frames, fn
          %{"in_app" => false} = f -> Map.put(f, "function", "renamedNativeTick")
          f -> f
        end)
      end)

    assert Fingerprint.compute(event) == Fingerprint.compute(other)
  end

  test "явный fingerprint переопределяет всё" do
    a = bun_event(%{"fingerprint" => ["payment", "timeout"]})
    b = bun_event(%{"fingerprint" => ["payment", "timeout"], "exception" => nil})
    c = bun_event(%{"fingerprint" => ["payment", "other"]})

    assert Fingerprint.compute(a) == Fingerprint.compute(b)
    refute Fingerprint.compute(a) == Fingerprint.compute(c)
  end

  test "{{ default }} комбинируется с явными частями" do
    plain = bun_event()
    scoped = bun_event(%{"fingerprint" => ["{{ default }}", "tenant-7"]})

    refute Fingerprint.compute(plain) == Fingerprint.compute(scoped)
  end

  test "exception голым списком (форма sentry-go) эквивалентен форме values" do
    wrapped = bun_event()
    bare = Map.put(wrapped, "exception", wrapped["exception"]["values"])

    assert Fingerprint.compute(wrapped) == Fingerprint.compute(bare)
  end

  test "без стектрейса группирует по типу и нормализованному значению" do
    a = %{"exception" => %{"values" => [%{"type" => "ValueError", "value" => "id 123 missing"}]}}
    b = %{"exception" => %{"values" => [%{"type" => "ValueError", "value" => "id 456 missing"}]}}
    c = %{"exception" => %{"values" => [%{"type" => "KeyError", "value" => "id 123 missing"}]}}

    assert Fingerprint.compute(a) == Fingerprint.compute(b)
    refute Fingerprint.compute(a) == Fingerprint.compute(c)
  end

  test "message-события: интерполяции не дробят группу" do
    a = %{"message" => "user 1001 not found"}
    b = %{"message" => "user 2002 not found"}
    c = %{"message" => "payment declined"}

    assert Fingerprint.compute(a) == Fingerprint.compute(b)
    refute Fingerprint.compute(a) == Fingerprint.compute(c)
  end

  test "message объектом: шаблон группирует, интерполяции не дробят" do
    a = %{"message" => %{"message" => "user %s missing", "formatted" => "user alice missing"}}
    b = %{"message" => %{"message" => "user %s missing", "formatted" => "user bob missing"}}

    assert Fingerprint.compute(a) == Fingerprint.compute(b)
  end

  test "fallback для пустого события" do
    assert Fingerprint.compute(%{}) =~ ~r/^[0-9a-f]{64}$/
  end
end
