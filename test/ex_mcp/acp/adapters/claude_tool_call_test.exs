defmodule ExMCP.ACP.Adapters.ClaudeToolCallTest do
  @moduledoc """
  The FIRST report of a Claude CLI tool_use block must be the ACP spec's
  `tool_call` — clients ignore a `tool_call_update` for a call id they were
  never introduced to, so the call previously surfaced only at its terminal
  update (after any streamed reply text, wrecking transcript order). The
  terminal update, built from a `tool_result` block that only carries the
  tool_use_id, must echo the remembered `toolName`.
  """

  use ExUnit.Case, async: true

  alias ExMCP.ACP.Adapters.Claude

  test "tool_use emits a spec tool_call and the tool_result echoes its toolName" do
    {:ok, state} = Claude.init([])
    state = %{state | session_id: "sess-1"}

    assistant =
      Jason.encode!(%{
        "type" => "assistant",
        "message" => %{
          "id" => "sess-1",
          "content" => [
            %{
              "type" => "tool_use",
              "id" => "toolu_1",
              "name" => "Bash",
              "input" => %{"command" => "ls"}
            }
          ]
        }
      })

    assert {:messages, [notification], state} = Claude.translate_inbound(assistant, state)

    assert %{
             "method" => "session/update",
             "params" => %{
               "sessionId" => "sess-1",
               "update" =>
                 %{
                   "sessionUpdate" => "tool_call",
                   "toolCallId" => "toolu_1",
                   "toolName" => "Bash",
                   "status" => "in_progress",
                   "rawInput" => %{"command" => "ls"}
                 } = update
             }
           } = notification

    assert is_binary(update["title"])

    user =
      Jason.encode!(%{
        "type" => "user",
        "message" => %{
          "content" => [
            %{"type" => "tool_result", "tool_use_id" => "toolu_1", "content" => "ok"}
          ]
        }
      })

    assert {:messages, [completion], _state} = Claude.translate_inbound(user, state)

    assert %{
             "method" => "session/update",
             "params" => %{
               "update" => %{
                 "sessionUpdate" => "tool_call_update",
                 "toolCallId" => "toolu_1",
                 "toolName" => "Bash",
                 "status" => "completed"
               }
             }
           } = completion
  end

  test "a tool_result for an unknown call id omits toolName" do
    {:ok, state} = Claude.init([])
    state = %{state | session_id: "sess-2"}

    user =
      Jason.encode!(%{
        "type" => "user",
        "message" => %{
          "content" => [
            %{"type" => "tool_result", "tool_use_id" => "toolu_unseen", "content" => "ok"}
          ]
        }
      })

    assert {:messages, [completion], _state} = Claude.translate_inbound(user, state)

    update = completion["params"]["update"]
    assert update["sessionUpdate"] == "tool_call_update"
    refute Map.has_key?(update, "toolName")
  end
end
