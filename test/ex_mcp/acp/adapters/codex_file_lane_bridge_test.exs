defmodule ExMCP.ACP.Adapters.CodexFileLaneBridgeTest do
  use ExUnit.Case, async: false

  alias ExMCP.ACP.AdapterTransport
  alias ExMCP.ACP.Adapters.Codex
  alias ExMCP.ACP.Client
  alias ExMCP.Test.CodexFileLaneHandler

  test "round-trips a Codex dynamic tool through AdapterBridge and ACP Client" do
    script = Path.expand("test/support/fake_codex_file_lane.exs")

    client =
      start_supervised!({
        Client,
        transport_mod: AdapterTransport,
        adapter: Codex,
        adapter_opts: [
          command_wrapper:
            {System.find_executable("mix"), ["run", "--no-start", "--no-compile", script, "--"]}
        ],
        handler: CodexFileLaneHandler,
        handler_opts: [test_pid: self()],
        capabilities: %{
          "fs" => %{"readTextFile" => true, "writeTextFile" => true}
        }
      })

    assert {:ok, %{"sessionId" => session_id}} = Client.new_session(client, File.cwd!())
    assert session_id == "thread-file-lane"

    task = Task.async(fn -> Client.prompt(client, session_id, "read the brief") end)

    assert_receive {:fake_session_update, ^session_id,
                    %{
                      "sessionUpdate" => "file_operation",
                      "fileOperationId" => "dynamic-item-1",
                      "operation" => "read_text_file",
                      "kind" => "read",
                      "path" => "brief.md",
                      "status" => "in_progress"
                    } = read_started},
                   5_000

    assert_metadata_only(read_started)

    assert_receive {:fake_file_read, ^session_id, "brief.md", %{}}, 5_000

    assert_receive {:fake_session_update, ^session_id,
                    %{
                      "sessionUpdate" => "file_operation_update",
                      "fileOperationId" => "dynamic-item-1",
                      "operation" => "read_text_file",
                      "kind" => "read",
                      "path" => "brief.md",
                      "status" => "completed"
                    } = read_completed},
                   5_000

    assert_metadata_only(read_completed)

    assert_receive {:fake_session_update, ^session_id,
                    %{
                      "sessionUpdate" => "file_operation",
                      "fileOperationId" => "dynamic-item-2",
                      "operation" => "edit_text_file",
                      "kind" => "edit",
                      "path" => "brief.md",
                      "status" => "in_progress"
                    } = edit_started},
                   5_000

    assert_metadata_only(edit_started)

    assert_receive {:fake_file_read, ^session_id, "brief.md", %{}}, 5_000

    expected_sha256 =
      :crypto.hash(:sha256, "brokered ACP content") |> Base.encode16(case: :lower)

    assert_receive {:fake_file_write, ^session_id, "brief.md", "edited ACP content",
                    %{"expectedSha256" => ^expected_sha256}},
                   5_000

    assert_receive {:fake_session_update, ^session_id,
                    %{
                      "sessionUpdate" => "file_operation_update",
                      "fileOperationId" => "dynamic-item-2",
                      "operation" => "edit_text_file",
                      "kind" => "edit",
                      "path" => "brief.md",
                      "status" => "completed"
                    } = edit_completed},
                   5_000

    assert_metadata_only(edit_completed)

    assert {:ok, %{"stopReason" => "end_turn"}} = Task.await(task, 5_000)

    refute_received {:fake_session_update, ^session_id, %{"sessionUpdate" => "tool_call"}}

    refute_received {:fake_session_update, ^session_id, %{"sessionUpdate" => "tool_call_update"}}
  end

  defp assert_metadata_only(update) do
    assert Map.keys(update) |> Enum.sort() ==
             ~w(fileOperationId kind operation path sessionUpdate status)
  end
end
