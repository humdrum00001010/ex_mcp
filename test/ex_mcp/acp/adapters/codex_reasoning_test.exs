defmodule ExMCP.ACP.Adapters.CodexReasoningTest do
  use ExUnit.Case, async: true

  alias ExMCP.ACP.Adapters.Codex

  test "summaryTextDelta becomes an ACP thought chunk" do
    {:ok, state} = Codex.init([])
    state = %{state | thread_id: "thr-reasoning"}

    inbound =
      Jason.encode!(%{
        "method" => "item/reasoning/summaryTextDelta",
        "params" => %{"itemId" => "reasoning-1", "delta" => "Inspect workspace"}
      })

    assert {:messages, [message], _state} = Codex.translate_inbound(inbound, state)

    assert %{
             "sessionUpdate" => "agent_thought_chunk",
             "content" => %{"type" => "text", "text" => "Inspect workspace"}
           } = get_in(message, ["params", "update"])

    assert get_in(message, ["params", "sessionId"]) == "thr-reasoning"
  end

  test "summaryPartAdded becomes an ACP thought chunk" do
    {:ok, state} = Codex.init([])
    state = %{state | thread_id: "thr-reasoning"}

    inbound =
      Jason.encode!(%{
        "method" => "item/reasoning/summaryPartAdded",
        "params" => %{"itemId" => "reasoning-1", "summary" => "Review result"}
      })

    assert {:messages, [message], _state} = Codex.translate_inbound(inbound, state)

    assert %{
             "sessionUpdate" => "agent_thought_chunk",
             "content" => %{"type" => "text", "text" => "Review result"}
           } = get_in(message, ["params", "update"])
  end
end
