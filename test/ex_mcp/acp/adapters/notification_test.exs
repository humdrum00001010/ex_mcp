defmodule ExMCP.ACP.Adapters.NotificationTest do
  @moduledoc """
  Regression tests for provider→client notifications that previously fell
  through the adapters' catch-alls and were dropped as "Unhandled".

  These drive `translate_inbound/2` directly with the exact NDJSON line a
  provider would emit and assert the adapter forwards a structured
  `session/update` (rather than silently skipping).
  """

  use ExUnit.Case, async: true

  alias ExMCP.ACP.Adapters.Claude
  alias ExMCP.ACP.Adapters.Codex

  import ExUnit.CaptureLog

  # ── Codex: account/rateLimits/updated ──────────────────────────

  describe "Codex handle_notification account/rateLimits/updated" do
    test "forwards the rate-limit snapshot as a session/update rate_limit variant" do
      {:ok, state} = Codex.init([])
      state = %{state | thread_id: "thr_123"}

      # Shape per codex-rs app-server-protocol v2 AccountRateLimitsUpdatedNotification.
      rate_limits = %{
        "limitId" => "codex",
        "limitName" => "Codex",
        "primary" => %{
          "usedPercent" => 42,
          "windowDurationMins" => 300,
          "resetsAt" => 1_900_000_000
        },
        "secondary" => %{
          "usedPercent" => 7,
          "windowDurationMins" => 10_080,
          "resetsAt" => 1_900_500_000
        },
        "planType" => "plus"
      }

      line =
        Jason.encode!(%{
          "method" => "account/rateLimits/updated",
          "params" => %{"rateLimits" => rate_limits}
        })

      assert {:messages, [notification], _new_state} = Codex.translate_inbound(line, state)

      assert %{
               "jsonrpc" => "2.0",
               "method" => "session/update",
               "params" => %{
                 "sessionId" => "thr_123",
                 "update" => %{
                   "sessionUpdate" => "rate_limit",
                   "content" => ^rate_limits
                 }
               }
             } = notification
    end

    test "does not log an 'Unhandled'/'unsurfaced' catch-all line for rate limits" do
      {:ok, state} = Codex.init([])

      line =
        Jason.encode!(%{
          "method" => "account/rateLimits/updated",
          "params" => %{"rateLimits" => %{"primary" => %{"usedPercent" => 1}}}
        })

      log =
        capture_log(fn ->
          assert {:messages, [_notification], _state} = Codex.translate_inbound(line, state)
        end)

      refute log =~ "Unhandled notification"
      refute log =~ "unsurfaced notification: account/rateLimits/updated"
    end

    test "handles a missing/empty rateLimits payload defensively without crashing" do
      {:ok, state} = Codex.init([])

      # No "rateLimits" key at all — must not raise; forwards whatever arrived.
      line = Jason.encode!(%{"method" => "account/rateLimits/updated", "params" => %{}})

      assert {:messages, [notification], _state} = Codex.translate_inbound(line, state)

      assert get_in(notification, ["params", "update", "sessionUpdate"]) == "rate_limit"
    end
  end

  # ── Claude: system subtype events (previously dropped) ──────────

  describe "Claude system subtype events" do
    test "api_retry is surfaced as a rate_limited status (was silently dropped)" do
      {:ok, state} = Claude.init([])
      state = %{state | session_id: "sess_1"}

      line =
        Jason.encode!(%{
          "type" => "system",
          "subtype" => "api_retry",
          "attempt" => 2,
          "max_retries" => 5,
          "retry_delay_ms" => 1500,
          "error_status" => 529,
          "error" => "overloaded_error",
          "session_id" => "sess_1"
        })

      assert {:messages, [notification], _state} = Claude.translate_inbound(line, state)

      assert %{
               "params" => %{
                 "update" => %{
                   "sessionUpdate" => "status",
                   "status" => "rate_limited",
                   "subtype" => "api_retry",
                   "attempt" => 2,
                   "maxRetries" => 5,
                   "retryAfter" => 1500
                 }
               }
             } = notification
    end

    test "init captures session_id/model and surfaces an info status" do
      {:ok, state} = Claude.init([])

      line =
        Jason.encode!(%{
          "type" => "system",
          "subtype" => "init",
          "session_id" => "sess_init",
          "model" => "claude-opus-4",
          "mcp_servers" => [%{"name" => "ecrits_doc", "status" => "connected"}]
        })

      assert {:messages, [notification], new_state} = Claude.translate_inbound(line, state)

      assert new_state.session_id == "sess_init"
      assert new_state.model == "claude-opus-4"

      assert get_in(notification, ["params", "update", "sessionUpdate"]) == "status"
      assert get_in(notification, ["params", "update", "status"]) == "info"
      assert get_in(notification, ["params", "update", "subtype"]) == "init"
    end

    test "a system event with a free-form message (legacy shape) still works" do
      {:ok, state} = Claude.init([])
      state = %{state | session_id: "sess_2"}

      line = Jason.encode!(%{"type" => "system", "message" => "compacting context"})

      assert {:messages, [notification], _state} = Claude.translate_inbound(line, state)
      assert get_in(notification, ["params", "update", "status"]) == "info"
      assert get_in(notification, ["params", "update", "message"]) == "compacting context"
    end

    test "an unknown system subtype is an intentional skip, not a crash" do
      {:ok, state} = Claude.init([])

      line = Jason.encode!(%{"type" => "system", "subtype" => "totally_new_thing"})

      assert {:skip, _state} = Claude.translate_inbound(line, state)
    end
  end
end
