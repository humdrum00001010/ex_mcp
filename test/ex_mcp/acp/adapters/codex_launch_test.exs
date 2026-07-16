defmodule ExMCP.ACP.Adapters.CodexLaunchTest do
  use ExUnit.Case, async: true

  alias ExMCP.ACP.Adapters.Codex

  test "does not change a host's memory policy by default" do
    assert {"codex", ["app-server"]} = Codex.command([])
  end

  test "can isolate an embedded ACP turn from personal memories" do
    assert {"codex", args} = Codex.command(disable_memories: true)

    assert args == [
             "app-server",
             "-c",
             "memories.use_memories=false",
             "-c",
             "memories.generate_memories=false"
           ]
  end

  test "can wrap the app server command without changing its arguments" do
    assert {"sandbox-exec", ["-p", "(version 1)", "codex" | args]} =
             Codex.command(command_wrapper: {"sandbox-exec", ["-p", "(version 1)"]})

    assert args == ["app-server"]
  end
end
