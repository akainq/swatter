defmodule Swatter.Ingest.EnvelopeTest do
  use ExUnit.Case, async: true

  alias Swatter.Ingest.Envelope

  describe "parse_header/1" do
    test "разбирает первую строку envelope" do
      body = ~s({"event_id":"a1","sent_at":"2026-07-02T12:00:00Z"}\n{"type":"event"}\n{})
      assert {:ok, %{"event_id" => "a1", "sent_at" => _}} = Envelope.parse_header(body)
    end

    test "envelope из одного заголовка без перевода строки" do
      assert {:ok, %{}} = Envelope.parse_header("{}")
    end

    test "терпит \\r\\n" do
      assert {:ok, %{"event_id" => "x"}} = Envelope.parse_header("{\"event_id\":\"x\"}\r\n{}")
    end

    test "ошибка на не-JSON" do
      assert {:error, :invalid_envelope} = Envelope.parse_header("garbage")
    end

    test "ошибка, если заголовок не объект" do
      assert {:error, :invalid_envelope} = Envelope.parse_header("[1,2]\n{}")
    end
  end

  describe "parse/1" do
    test "item с length: payload берётся побайтово (включая переводы строк)" do
      payload = "line1\nline2\n{}"
      item_header = Jason.encode!(%{"type" => "attachment", "length" => byte_size(payload)})
      body = "{}\n" <> item_header <> "\n" <> payload <> "\n"

      assert {:ok, %{}, [{header, ^payload}]} = Envelope.parse(body)
      assert header["type"] == "attachment"
    end

    test "item без length: payload до конца строки" do
      body = ~s({}\n{"type":"session"}\n{"sid":"abc"}\n)
      assert {:ok, %{}, [{%{"type" => "session"}, ~s({"sid":"abc"})}]} = Envelope.parse(body)
    end

    test "несколько items подряд (session + event, как шлёт @sentry/bun)" do
      event = ~s({"event_id":"aa"})

      body =
        Enum.join(
          [
            ~s({"sent_at":"2026-07-02T12:00:00Z"}),
            ~s({"type":"session"}),
            ~s({"sid":"s1"}),
            Jason.encode!(%{"type" => "event", "length" => byte_size(event)}),
            event
          ],
          "\n"
        )

      assert {:ok, header, [{s_header, _}, {e_header, ^event}]} = Envelope.parse(body)
      assert header["sent_at"]
      assert s_header["type"] == "session"
      assert e_header["type"] == "event"
    end

    test "работает без финального перевода строки" do
      body = ~s({}\n{"type":"event"}\n{"a":1})
      assert {:ok, %{}, [{_, ~s({"a":1})}]} = Envelope.parse(body)
    end

    test "envelope только из заголовка" do
      assert {:ok, %{"dsn" => _}, []} = Envelope.parse(~s({"dsn":"x"}\n))
    end

    test "битый заголовок item — ошибка" do
      assert {:error, :invalid_envelope} = Envelope.parse("{}\nnot-json\npayload\n")
    end

    test "length больше остатка тела — ошибка" do
      assert {:error, :invalid_envelope} =
               Envelope.parse(~s({}\n{"type":"event","length":999}\nshort))
    end
  end

  describe "event_id/1" do
    test "нормализует UUID с дефисами к 32 hex" do
      header = %{"event_id" => "9ABCDEF0-1234-5678-9ABC-DEF012345678"}
      assert Envelope.event_id(header) == "9abcdef0123456789abcdef012345678"
    end

    test "генерирует id, когда его нет в заголовке" do
      assert Envelope.event_id(%{}) =~ ~r/^[0-9a-f]{32}$/
    end
  end
end
