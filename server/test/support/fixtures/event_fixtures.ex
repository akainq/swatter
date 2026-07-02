defmodule Swatter.EventFixtures do
  @moduledoc """
  Фикстуры событий. `bun_event/1` повторяет структуру реального события
  от @sentry/bun 10.x (снято с живого SDK при разработке среза).
  """

  def bun_event(overrides \\ %{}) do
    Map.merge(
      %{
        "event_id" => "21f67d46821d4f40b82f00af3c192558",
        "level" => "error",
        "platform" => "node",
        "timestamp" => 1_782_992_354.448,
        "environment" => "conformance",
        "release" => "conformance@0.0.1",
        "server_name" => "testhost",
        "exception" => %{
          "values" => [
            %{
              "type" => "Error",
              "value" => "conformance: hello from @sentry/bun",
              "stacktrace" => %{
                "frames" => [
                  %{
                    "filename" => "native",
                    "module" => "native",
                    "function" => "processTicksAndRejections",
                    "lineno" => 7,
                    "colno" => 39,
                    "in_app" => false
                  },
                  %{
                    "filename" =>
                      "C:\\projects\\research\\swatter\\conformance\\bun\\send_error.ts",
                    "module" => "send_error.ts",
                    "function" => "?",
                    "lineno" => 18,
                    "colno" => 29,
                    "in_app" => true
                  }
                ]
              },
              "mechanism" => %{"type" => "generic", "handled" => true}
            }
          ]
        },
        "contexts" => %{
          "trace" => %{
            "trace_id" => "4541246aa98542e4980c637cd76e4b1a",
            "span_id" => "90e09c8120548516"
          },
          "runtime" => %{"name" => "bun", "version" => "1.3.13"}
        },
        "sdk" => %{"name" => "sentry.javascript.bun", "version" => "10.63.0"},
        "user" => %{"id" => "u-42", "email" => "dev@example.com", "ip_address" => "127.0.0.1"},
        "tags" => %{"feature" => "checkout", "shard" => 7}
      },
      overrides
    )
  end

  @doc "Envelope c одним event-item (length-based payload)."
  def envelope_with_event(event) do
    payload = Jason.encode!(event)

    Enum.join(
      [
        Jason.encode!(%{"event_id" => event["event_id"], "sent_at" => "2026-07-02T12:00:00Z"}),
        Jason.encode!(%{"type" => "event", "length" => byte_size(payload)}),
        payload
      ],
      "\n"
    ) <> "\n"
  end
end
