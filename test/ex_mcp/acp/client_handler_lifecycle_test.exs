defmodule ExMCP.ACP.ClientHandlerLifecycleTest do
  use ExUnit.Case, async: false

  alias ExMCP.ACP.Client
  alias ExMCP.ACP.Client.HandlerRunner
  alias ExMCP.Test.BlockingFileWriteHandler

  test "stopping the client cancels a blocked file handler before it can mutate the file" do
    {client, handler, path} = start_blocked_file_write()
    handler_ref = Process.monitor(handler)

    :ok = GenServer.stop(client, :normal, 1_000)
    assert_receive {:DOWN, ^handler_ref, :process, ^handler, _reason}

    send(handler, :finish_file_write)
    refute_receive {:blocking_file_write_finished, ^handler}
    assert File.read!(path) == "before"
  end

  test "a brutally killed client cannot orphan its blocked file handler" do
    {client, handler, path} = start_blocked_file_write()
    client_ref = Process.monitor(client)
    handler_ref = Process.monitor(handler)

    Process.exit(client, :kill)

    assert_receive {:DOWN, ^client_ref, :process, ^client, :killed}
    assert_receive {:DOWN, ^handler_ref, :process, ^handler, :killed}

    send(handler, :finish_file_write)
    refute_receive {:blocking_file_write_finished, ^handler}
    assert File.read!(path) == "before"
  end

  test "killing the client during graceful termination cannot sever handler ownership" do
    {client, handler, path} = start_blocked_file_write()
    client_ref = Process.monitor(client)
    handler_ref = Process.monitor(handler)

    :erlang.trace_pattern({Client, :terminate, 2}, true, [])
    :erlang.trace(client, true, [:call])

    on_exit(fn ->
      :erlang.trace_pattern({Client, :terminate, 2}, false, [])
    end)

    stopper =
      Task.async(fn ->
        try do
          {:ok, GenServer.stop(client, :normal, 5_000)}
        catch
          :exit, reason -> {:exit, reason}
        end
      end)

    assert_receive {:trace, ^client, :call, {Client, :terminate, [_reason, _state]}}, 1_000
    assert Process.alive?(handler)

    Process.exit(client, :kill)

    assert_receive {:DOWN, ^client_ref, :process, ^client, :killed}
    assert_receive {:DOWN, ^handler_ref, :process, ^handler, :killed}
    assert match?({:exit, _reason}, Task.await(stopper, 1_000))

    send(handler, :finish_file_write)
    refute_receive {:blocking_file_write_finished, ^handler}
    assert File.read!(path) == "before"
  end

  test "explicit disconnect terminates a blocked handler" do
    {client, handler, path} = start_blocked_file_write()
    handler_ref = Process.monitor(handler)

    assert :ok = Client.disconnect(client)
    assert_receive {:DOWN, ^handler_ref, :process, ^handler, _reason}

    state = :sys.get_state(client)
    assert state.status == :disconnected
    assert state.handler_pid == nil
    assert state.pending_agent_requests == %{}
    assert File.read!(path) == "before"
  end

  test "terminal transport closure terminates a blocked handler" do
    {client, handler, path} = start_blocked_file_write()
    handler_ref = Process.monitor(handler)

    send(client, {:transport_closed, :test_closed})
    state = :sys.get_state(client)

    assert_receive {:DOWN, ^handler_ref, :process, ^handler, _reason}
    assert state.status == :disconnected
    assert state.handler_pid == nil
    assert state.pending_agent_requests == %{}
    assert File.read!(path) == "before"
  end

  defp start_blocked_file_write do
    path =
      Path.join(
        System.tmp_dir!(),
        "ex_mcp-blocked-write-#{System.unique_integer([:positive])}"
      )

    File.write!(path, "before")
    on_exit(fn -> File.rm(path) end)

    client =
      start_supervised!(
        Supervisor.child_spec(
          {Client,
           [
             _skip_connect: true,
             handler: BlockingFileWriteHandler,
             handler_opts: [test_pid: self()]
           ]},
          restart: :temporary
        )
      )

    handler = :sys.get_state(client).handler_pid

    HandlerRunner.file_write(
      handler,
      make_ref(),
      "session-1",
      path,
      "after",
      %{"expectedSha256" => String.duplicate("0", 64)}
    )

    assert_receive {:blocking_file_write_started, ^handler}
    {client, handler, path}
  end
end
