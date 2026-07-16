defmodule ExMCP.ACP.Adapters.CodexMcpConfigTest do
  use ExUnit.Case, async: true

  alias ExMCP.ACP.Adapters.Codex

  test "maps ACP session/new MCP servers into thread/start config" do
    {:ok, state} = Codex.init([])

    mcp_servers = [
      %{"name" => "doc", "url" => "http://127.0.0.1:4000/mcp/doc"},
      %{
        "type" => "http",
        "name" => "remote",
        "url" => "https://mcp.example.test",
        "headers" => [%{"name" => "Authorization", "value" => "Bearer test"}]
      },
      %{
        "type" => "stdio",
        "name" => "local",
        "command" => "node",
        "args" => ["server.js", "--quiet"],
        "env" => [%{"name" => "MCP_TOKEN", "value" => "secret"}]
      }
    ]

    assert {:ok, request, _state} =
             Codex.translate_outbound(
               %{
                 "method" => "session/new",
                 "id" => 1,
                 "params" => %{"cwd" => "/workspace", "mcpServers" => mcp_servers}
               },
               state
             )

    assert %{
             "method" => "thread/start",
             "params" => %{
               "config" => %{
                 "mcp_servers" => %{
                   "doc" => %{
                     "url" => "http://127.0.0.1:4000/mcp/doc",
                     "startup_timeout_sec" => 30,
                     "tool_timeout_sec" => 120
                   },
                   "remote" => %{
                     "url" => "https://mcp.example.test",
                     "http_headers" => %{"Authorization" => "Bearer test"},
                     "startup_timeout_sec" => 30,
                     "tool_timeout_sec" => 120
                   },
                   "local" => %{
                     "command" => "node",
                     "args" => ["server.js", "--quiet"],
                     "env" => %{"MCP_TOKEN" => "secret"},
                     "startup_timeout_sec" => 30,
                     "tool_timeout_sec" => 120
                   }
                 }
               }
             }
           } = decode_request(request)
  end

  test "maps ACP session/load MCP servers into thread/resume config" do
    {:ok, state} = Codex.init([])

    assert {:ok, request, _state} =
             Codex.translate_outbound(
               %{
                 "method" => "session/load",
                 "id" => 2,
                 "params" => %{
                   "sessionId" => "thread-123",
                   "cwd" => "/workspace",
                   "mcpServers" => [
                     %{
                       "type" => "stdio",
                       "name" => "local",
                       "command" => "elixir",
                       "args" => ["server.exs"],
                       "env" => [%{"name" => "MODE", "value" => "test"}]
                     }
                   ]
                 }
               },
               state
             )

    assert %{
             "method" => "thread/resume",
             "params" => %{
               "threadId" => "thread-123",
               "config" => %{
                 "mcp_servers" => %{
                   "local" => %{
                     "command" => "elixir",
                     "args" => ["server.exs"],
                     "env" => %{"MODE" => "test"},
                     "startup_timeout_sec" => 30,
                     "tool_timeout_sec" => 120
                   }
                 }
               }
             }
           } = decode_request(request)
  end

  test "does not inject MCP configuration into the app-server command" do
    assert {"codex", ["app-server"]} =
             Codex.command(
               mcp_servers: [%{"name" => "doc", "url" => "http://127.0.0.1:4000/mcp/doc"}]
             )
  end

  defp decode_request(request) do
    request
    |> IO.iodata_to_binary()
    |> Jason.decode!()
  end
end
