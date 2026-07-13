defmodule ExMCP.Server.StdioServerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  defmodule Handler do
    use ExMCP.Server.Handler
    use ExMCP.Server.DSL, name: "stdio-test", version: "1.0.0"
  end

  setup do
    previous_delay = Application.get_env(:ex_mcp, :stdio_startup_delay)
    Application.put_env(:ex_mcp, :stdio_startup_delay, 60_000)

    on_exit(fn ->
      if is_nil(previous_delay) do
        Application.delete_env(:ex_mcp, :stdio_startup_delay)
      else
        Application.put_env(:ex_mcp, :stdio_startup_delay, previous_delay)
      end
    end)
  end

  test "initialized and unknown notifications produce no JSON-RPC response" do
    output =
      capture_io(fn ->
        {:ok, server} = ExMCP.Server.StdioServer.start_link(module: Handler)

        send(
          server,
          {:stdin_line,
           Jason.encode!(%{
             "jsonrpc" => "2.0",
             "method" => "notifications/initialized",
             "params" => %{}
           })}
        )

        send(
          server,
          {:stdin_line,
           Jason.encode!(%{
             "jsonrpc" => "2.0",
             "method" => "notifications/unknown",
             "params" => %{}
           })}
        )

        _ = :sys.get_state(server)
        GenServer.stop(server)
      end)

    assert output == ""
  end
end
