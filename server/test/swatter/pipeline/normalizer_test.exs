defmodule Swatter.Pipeline.NormalizerTest do
  use ExUnit.Case, async: true

  import Swatter.EventFixtures

  alias Swatter.Pipeline.Normalizer

  @received_at ~U[2026-07-02 12:00:00.000000Z]

  test "нормализует реальное событие @sentry/bun" do
    n = Normalizer.normalize(bun_event(), @received_at)

    assert n.event_id == "21f67d46821d4f40b82f00af3c192558"
    assert n.level == "error"
    assert n.exception_type == "Error"
    assert n.exception_value == "conformance: hello from @sentry/bun"
    assert n.title == "Error: conformance: hello from @sentry/bun"
    assert n.culprit == "send_error.ts in ?"
    assert n.release == "conformance@0.0.1"
    assert n.environment == "conformance"
    assert n.platform == "node"
    assert n.sdk_name == "sentry.javascript.bun"
    assert n.sdk_version == "10.63.0"
    assert n.user_id == "u-42"
    assert n.user_email == "dev@example.com"
    assert n.user_ip == "127.0.0.1"
    assert n.trace_id == "4541246aa98542e4980c637cd76e4b1a"
    assert n.tags == %{"feature" => "checkout", "shard" => "7"}
    assert n.fingerprint_hash =~ ~r/^[0-9a-f]{64}$/
    assert n.grouping_version == 1
    assert %DateTime{} = n.timestamp
    assert DateTime.to_unix(n.timestamp, :millisecond) == 1_782_992_354_448
    assert Jason.decode!(n.payload)["event_id"] == n.event_id
  end

  test "exception голым списком (форма sentry-go) нормализуется" do
    event = bun_event()
    bare = Map.put(event, "exception", event["exception"]["values"])

    n = Normalizer.normalize(bare, @received_at)
    assert n.exception_type == "Error"
    assert n.culprit == "send_error.ts in ?"
  end

  test "timestamp: ISO-строка, число и мусор" do
    iso = Normalizer.normalize(%{"timestamp" => "2026-07-01T10:00:00Z"}, @received_at)
    assert DateTime.compare(iso.timestamp, ~U[2026-07-01 10:00:00Z]) == :eq

    garbage = Normalizer.normalize(%{"timestamp" => "not a date"}, @received_at)
    assert garbage.timestamp == @received_at

    missing = Normalizer.normalize(%{}, @received_at)
    assert missing.timestamp == @received_at
  end

  test "timestamp из будущего прижимается к received_at" do
    future = DateTime.add(@received_at, 3600, :second) |> DateTime.to_unix()
    n = Normalizer.normalize(%{"timestamp" => future}, @received_at)
    assert n.timestamp == @received_at
  end

  test "event_id: с дефисами нормализуется, мусорный заменяется" do
    n =
      Normalizer.normalize(%{"event_id" => "9ABCDEF0-1234-5678-9ABC-DEF012345678"}, @received_at)

    assert n.event_id == "9abcdef0123456789abcdef012345678"

    n = Normalizer.normalize(%{"event_id" => "!!!"}, @received_at)
    assert n.event_id =~ ~r/^[0-9a-f]{32}$/
  end

  test "environment по умолчанию production, level нормализуется" do
    n = Normalizer.normalize(%{}, @received_at)
    assert n.environment == "production"
    assert n.level == "error"

    n = Normalizer.normalize(%{"level" => "WARNING"}, @received_at)
    assert n.level == "warning"

    n = Normalizer.normalize(%{"level" => "weird"}, @received_at)
    assert n.level == "error"
  end

  test "tags списком пар и с не-строками" do
    n = Normalizer.normalize(%{"tags" => [["a", 1], ["b", nil], ["c", "x"]]}, @received_at)
    assert n.tags == %{"a" => "1", "b" => "", "c" => "x"}
  end

  test "message-событие: title из message, culprit из transaction" do
    event = %{"message" => "boom happened", "transaction" => "GET /checkout"}
    n = Normalizer.normalize(event, @received_at)

    assert n.message == "boom happened"
    assert n.title == "boom happened"
    assert n.culprit == "GET /checkout"
    assert n.exception_type == ""
  end

  test "logentry.formatted приоритетнее message" do
    event = %{"logentry" => %{"formatted" => "user 7 failed", "message" => "user %d failed"}}
    n = Normalizer.normalize(event, @received_at)
    assert n.message == "user 7 failed"
  end

  test "message объектом (форма sentry-elixir) даёт message и title" do
    event = %{"message" => %{"formatted" => "hello from map form"}}
    n = Normalizer.normalize(event, @received_at)

    assert n.message == "hello from map form"
    assert n.title == "hello from map form"
  end

  test "все строковые поля не-nil (колонки CH не Nullable)" do
    n = Normalizer.normalize(%{}, @received_at)

    for {k, v} <- n, k not in [:timestamp, :received_at, :tags, :grouping_version] do
      assert is_binary(v), "#{k} должен быть строкой, а был: #{inspect(v)}"
    end

    assert n.tags == %{}
  end
end
