defmodule ExMCP.ACP.Adapters.CodexCommandExecutionTest do
  use ExUnit.Case, async: true

  alias ExMCP.ACP.Adapters.Codex

  test "current item commandExecution events become an ordered ACP tool call" do
    {:ok, state} = Codex.init([])
    state = %{state | thread_id: "thr-command"}

    started =
      Jason.encode!(%{
        "method" => "item/started",
        "params" => %{
          "item" => %{
            "id" => "call-shell",
            "type" => "commandExecution",
            "status" => "inProgress",
            "command" => "/bin/zsh -lc uuidgen",
            "aggregatedOutput" => nil,
            "exitCode" => nil
          }
        }
      })

    assert {:messages, [start_message], state} = Codex.translate_inbound(started, state)

    assert %{
             "sessionUpdate" => "tool_call",
             "toolCallId" => "call-shell",
             "title" => "/bin/zsh -lc uuidgen",
             "kind" => "execute",
             "status" => "in_progress",
             "rawInput" => %{"command" => "/bin/zsh -lc uuidgen"}
           } = get_in(start_message, ["params", "update"])

    completed =
      Jason.encode!(%{
        "method" => "item/completed",
        "params" => %{
          "item" => %{
            "id" => "call-shell",
            "type" => "commandExecution",
            "status" => "completed",
            "command" => "/bin/zsh -lc uuidgen",
            "aggregatedOutput" => "ABC-123\n",
            "exitCode" => 0
          }
        }
      })

    assert {:messages, [done_message], _state} = Codex.translate_inbound(completed, state)

    assert %{
             "sessionUpdate" => "tool_call_update",
             "toolCallId" => "call-shell",
             "toolName" => "/bin/zsh -lc uuidgen",
             "kind" => "execute",
             "status" => "completed",
             "rawOutput" => %{"exitCode" => 0, "output" => "ABC-123\n"}
           } = get_in(done_message, ["params", "update"])
  end
end
