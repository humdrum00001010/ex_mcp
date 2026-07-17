defmodule ExMCP.Test.CodexFileLaneHandler do
  @behaviour ExMCP.ACP.Client.Handler

  @impl true
  def init(opts), do: {:ok, %{test_pid: Keyword.fetch!(opts, :test_pid)}}

  @impl true
  def handle_session_update(_session_id, _update, state), do: {:ok, state}

  @impl true
  def handle_permission_request(_session_id, _tool_call, _options, state) do
    {:ok, %{"outcome" => "cancelled"}, state}
  end

  @impl true
  def handle_file_read(session_id, path, opts, state) do
    send(state.test_pid, {:fake_file_read, session_id, path, opts})
    {:ok, "brokered ACP content", state}
  end

  @impl true
  def handle_file_write(session_id, path, content, opts, state) do
    send(state.test_pid, {:fake_file_write, session_id, path, content, opts})
    {:ok, state}
  end
end
