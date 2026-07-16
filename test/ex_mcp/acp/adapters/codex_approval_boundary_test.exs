defmodule ExMCP.ACP.Adapters.CodexApprovalBoundaryTest do
  use ExUnit.Case, async: true

  alias ExMCP.ACP.Adapters.Codex

  test "workspace-write auto-approves configured MCP calls but not shell escalation" do
    {:ok, state} =
      Codex.init(
        approvalPolicy: "never",
        sandbox: "workspace-write",
        auto_approve_mcp_servers: ["doc"]
      )

    assert {"accept", _state} = approval_action("mcpServer/elicitation/request", state, "doc")
    assert {"decline", _state} = approval_action("mcpServer/elicitation/request", state, "other")
    assert {"decline", _state} = approval_decision("item/commandExecution/requestApproval", state)
    assert {"decline", _state} = approval_decision("item/fileChange/requestApproval", state)
  end

  test "ask mode does not auto-approve even a configured MCP server" do
    {:ok, state} =
      Codex.init(
        approvalPolicy: "on-request",
        sandbox: "workspace-write",
        auto_approve_mcp_servers: ["doc"]
      )

    assert {"decline", _state} = approval_action("mcpServer/elicitation/request", state, "doc")
  end

  test "legacy shell escalation is denied even with workspace-write" do
    {:ok, state} = Codex.init(approvalPolicy: "never", sandbox: "workspace-write")

    assert {"denied", _state} = approval_decision("execCommandApproval", state)
    assert {"denied", _state} = approval_decision("applyPatchApproval", state)
  end

  defp approval_action(method, state, server_name) do
    assert {:skip_and_write, response, state} =
             Codex.translate_inbound(request(method, server_name), state)

    {response |> Jason.decode!() |> get_in(["result", "action"]), state}
  end

  defp approval_decision(method, state) do
    assert {:skip_and_write, response, state} = Codex.translate_inbound(request(method), state)
    {response |> Jason.decode!() |> get_in(["result", "decision"]), state}
  end

  defp request(method, server_name \\ "doc") do
    Jason.encode!(%{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => method,
      "params" => %{"serverName" => server_name}
    })
  end
end
