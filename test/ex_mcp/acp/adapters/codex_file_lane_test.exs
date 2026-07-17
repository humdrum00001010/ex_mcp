defmodule ExMCP.ACP.Adapters.CodexFileLaneTest do
  use ExUnit.Case, async: true

  alias ExMCP.ACP.Adapters.Codex

  test "initialize opts into the experimental API required by dynamic tools" do
    {:ok, state} = Codex.init([])

    assert {:ok, request, _state} = Codex.post_connect(state)

    assert get_in(decode(request), ["params", "capabilities", "experimentalApi"]) == true
  end

  test "advertised ACP filesystem capabilities become Codex dynamic tools" do
    state = initialized_state(%{"fs" => %{"readTextFile" => true, "writeTextFile" => true}})

    assert {:ok, request, _state} =
             Codex.translate_outbound(
               %{
                 "method" => "session/new",
                 "id" => 1,
                 "params" => %{"cwd" => "/workspace"}
               },
               state
             )

    names =
      request
      |> decode()
      |> get_in(["params", "dynamicTools"])
      |> Enum.map(& &1["name"])

    assert names == ["read_text_file", "search_text_file", "edit_text_file"]
  end

  test "ACP file tool descriptions do not prohibit shell search" do
    state = initialized_state(%{"fs" => %{"readTextFile" => true, "writeTextFile" => true}})

    assert {:ok, request, _state} =
             Codex.translate_outbound(
               %{
                 "method" => "session/new",
                 "id" => 1,
                 "params" => %{"cwd" => "/workspace"}
               },
               state
             )

    descriptions =
      request
      |> decode()
      |> get_in(["params", "dynamicTools"])
      |> Enum.map_join(" ", & &1["description"])

    refute descriptions =~ "Never use shell"
    refute descriptions =~ "instead of rg"
  end

  test "read_text_file round-trips through ACP fs/read_text_file" do
    state = initialized_state(%{"fs" => %{"readTextFile" => true}})

    assert {:messages, [request], state} =
             Codex.translate_inbound(
               Jason.encode!(%{
                 "id" => 41,
                 "method" => "item/tool/call",
                 "params" => %{
                   "threadId" => "thread-1",
                   "turnId" => "turn-1",
                   "callId" => "dynamic-call-41",
                   "namespace" => nil,
                   "tool" => "read_text_file",
                   "arguments" => %{"path" => "brief.md", "line" => 4, "limit" => 8}
                 }
               }),
               state
             )

    assert request["method"] == "fs/read_text_file"

    assert request["params"] == %{
             "sessionId" => "default",
             "path" => "brief.md",
             "line" => 4,
             "limit" => 8
           }

    assert {:ok, response, _state} =
             Codex.translate_outbound(
               %{
                 "jsonrpc" => "2.0",
                 "id" => request["id"],
                 "result" => %{"content" => "four\nfive"}
               },
               state
             )

    assert %{
             "id" => 41,
             "result" => %{
               "success" => true,
               "contentItems" => [%{"type" => "inputText", "text" => "four\nfive"}]
             }
           } = decode(response)
  end

  test "read_text_file pages through compact one-line JSONL by character offset" do
    state = initialized_state(%{"fs" => %{"readTextFile" => true}})

    assert {:messages, [request], state} =
             dynamic_call(state, 410, "read_text_file", %{
               "path" => "contract.jsonl",
               "offset" => 3,
               "max_chars" => 4
             })

    refute Map.has_key?(request["params"], "line")
    refute Map.has_key?(request["params"], "limit")

    assert {:ok, response, _state} =
             Codex.translate_outbound(
               %{"id" => request["id"], "result" => %{"content" => "가나다라마바사"}},
               state
             )

    result = get_in(decode(response), ["result", "contentItems", Access.at(0), "text"])

    assert result == "라마바사"
  end

  test "read_text_file returns the next offset when a chunk remains" do
    state = initialized_state(%{"fs" => %{"readTextFile" => true}})

    assert {:messages, [request], state} =
             dynamic_call(state, 411, "read_text_file", %{
               "path" => "contract.jsonl",
               "offset" => 2,
               "max_chars" => 3
             })

    assert {:ok, response, _state} =
             Codex.translate_outbound(
               %{"id" => request["id"], "result" => %{"content" => "abcdefgh"}},
               state
             )

    result = get_in(decode(response), ["result", "contentItems", Access.at(0), "text"])

    assert result == "cde\n[ACP chunk chars 2-4 of 8; continue with offset 5]"
  end

  test "read_text_file rejects ambiguous line and offset paging" do
    state = initialized_state(%{"fs" => %{"readTextFile" => true}})

    assert {:skip_and_write, response, _state} =
             dynamic_call(state, 412, "read_text_file", %{
               "path" => "contract.jsonl",
               "line" => 1,
               "offset" => 0
             })

    assert get_in(decode(response), ["result", "success"]) == false

    assert get_in(decode(response), ["result", "contentItems", Access.at(0), "text"]) =~
             "offset cannot be combined"
  end

  test "search_text_file searches ACP-provided content without a shell" do
    state = initialized_state(%{"fs" => %{"readTextFile" => true}})

    assert {:messages, [request], state} =
             dynamic_call(state, 42, "search_text_file", %{
               "path" => "contract.jsonl",
               "query" => "계약명"
             })

    assert {:ok, response, _state} =
             Codex.translate_outbound(
               %{
                 "id" => request["id"],
                 "result" => %{"content" => "첫 줄\n계약명: 빈칸\n끝"}
               },
               state
             )

    result = get_in(decode(response), ["result", "contentItems", Access.at(0), "text"])

    assert result =~ "match 1 at byte"
    assert result =~ "첫 줄\n계약명: 빈칸\n끝"
  end

  test "search_text_file enumerates repeated matches inside one compact JSON line" do
    state = initialized_state(%{"fs" => %{"readTextFile" => true}})

    assert {:messages, [request], state} =
             dynamic_call(state, 420, "search_text_file", %{
               "path" => "contract.jsonl",
               "query" => "(인)"
             })

    assert {:ok, response, _state} =
             Codex.translate_outbound(
               %{
                 "id" => request["id"],
                 "result" => %{
                   "content" => ~s|{"text":"갑 (인)","other":"을 (인)","last":"병 (인)"}|
                 }
               },
               state
             )

    result = get_in(decode(response), ["result", "contentItems", Access.at(0), "text"])

    assert result =~ "match 1 at byte"
    assert result =~ "match 2 at byte"
    assert result =~ "match 3 at byte"

    assert length(Regex.scan(~r/match \d+ at byte/, result)) == 3
  end

  test "search_text_file keeps UTF-8 snippets valid at bounded byte edges" do
    state = initialized_state(%{"fs" => %{"readTextFile" => true}})

    assert {:messages, [request], state} =
             dynamic_call(state, 421, "search_text_file", %{
               "path" => "contract.jsonl",
               "query" => "(인)"
             })

    content = String.duplicate("가", 500) <> "(인)" <> String.duplicate("나", 500)

    assert {:ok, response, _state} =
             Codex.translate_outbound(
               %{"id" => request["id"], "result" => %{"content" => content}},
               state
             )

    result = get_in(decode(response), ["result", "contentItems", Access.at(0), "text"])

    assert String.valid?(result)
    assert result =~ "(인)"
  end

  test "search_text_file bounds work and reports undisplayed occurrences" do
    state = initialized_state(%{"fs" => %{"readTextFile" => true}})

    assert {:messages, [request], state} =
             dynamic_call(state, 422, "search_text_file", %{
               "path" => "contract.jsonl",
               "query" => "(인)",
               "max_results" => 2
             })

    content = Enum.map_join(1..100, " ", &"#{&1}(인)")

    assert {:ok, response, _state} =
             Codex.translate_outbound(
               %{"id" => request["id"], "result" => %{"content" => content}},
               state
             )

    result = get_in(decode(response), ["result", "contentItems", Access.at(0), "text"])

    assert length(Regex.scan(~r/match \d+ at byte/, result)) == 2
    assert result =~ "More literal matches exist"
  end

  test "ACP file lane dynamic notifications emit metadata-only file activity using item ids" do
    state = initialized_state(%{"fs" => %{"readTextFile" => true, "writeTextFile" => true}})

    operations = [
      {"read_text_file", "read", %{"path" => "contract.jsonl", "max_chars" => 200_000}},
      {"search_text_file", "search",
       %{"path" => "contract.jsonl", "query" => "(인)", "max_results" => 5}},
      {"edit_text_file", "edit",
       %{
         "path" => "contract.jsonl",
         "edits" => [%{"old_text" => "private old content", "new_text" => "private new content"}]
       }}
    ]

    final_state =
      Enum.reduce(
        operations,
        state,
        fn {tool, kind, arguments}, current_state ->
          item_id = "#{tool}-item"

          started = %{
            "id" => item_id,
            "type" => "dynamicToolCall",
            "namespace" => nil,
            "tool" => tool,
            "arguments" => arguments,
            "status" => "inProgress",
            "contentItems" => nil,
            "success" => nil,
            "durationMs" => nil
          }

          assert {:messages, [started_message], started_state} =
                   item_notification(current_state, "item/started", started)

          assert %{
                   "sessionUpdate" => "file_operation",
                   "fileOperationId" => ^item_id,
                   "operation" => ^tool,
                   "kind" => ^kind,
                   "path" => "contract.jsonl",
                   "status" => "in_progress"
                 } = started_update = get_in(started_message, ["params", "update"])

          assert Map.keys(started_update) |> Enum.sort() ==
                   expected_file_operation_keys(tool, false)

          completed = %{
            "id" => item_id,
            "type" => "dynamicToolCall",
            "namespace" => nil,
            "tool" => tool,
            "arguments" => arguments,
            "status" => "completed",
            "success" => true,
            "contentItems" => [%{"type" => "inputText", "text" => "done"}],
            "durationMs" => 1
          }

          assert {:messages, [completed_message], completed_state} =
                   item_notification(started_state, "item/completed", completed)

          assert %{
                   "sessionUpdate" => "file_operation_update",
                   "fileOperationId" => ^item_id,
                   "operation" => ^tool,
                   "kind" => ^kind,
                   "path" => "contract.jsonl",
                   "status" => "completed"
                 } = completed_update = get_in(completed_message, ["params", "update"])

          assert Map.keys(completed_update) |> Enum.sort() ==
                   expected_file_operation_keys(tool, false)

          completed_state
        end
      )

    refute Map.has_key?(final_state, :file_lane_call_ids)
    refute Map.has_key?(final_state, :file_lane_calls)
  end

  test "item/tool/call request ids never replace Codex dynamic item ids" do
    state = initialized_state(%{"fs" => %{"readTextFile" => true}})

    item = %{
      "id" => "dynamic-item-9",
      "type" => "dynamicToolCall",
      "namespace" => nil,
      "tool" => "read_text_file",
      "arguments" => %{"path" => "contract.jsonl"},
      "status" => "inProgress",
      "contentItems" => nil,
      "success" => nil,
      "durationMs" => nil
    }

    assert {:messages, [started_message], state} =
             item_notification(state, "item/started", item)

    assert get_in(started_message, ["params", "update", "fileOperationId"]) ==
             "dynamic-item-9"

    assert {:messages, [_fs_request], state} =
             Codex.translate_inbound(
               Jason.encode!(%{
                 "id" => 700,
                 "method" => "item/tool/call",
                 "params" => %{
                   "threadId" => "thread-1",
                   "turnId" => "turn-1",
                   "callId" => "dynamic-call-9",
                   "namespace" => nil,
                   "tool" => "read_text_file",
                   "arguments" => %{"path" => "contract.jsonl", "max_chars" => 500_000}
                 }
               }),
               state
             )

    completed =
      Map.merge(item, %{
        "status" => "completed",
        "success" => true,
        "contentItems" => [%{"type" => "inputText", "text" => "done"}],
        "durationMs" => 1
      })

    assert {:messages, [completed_message], _state} =
             item_notification(state, "item/completed", completed)

    update = get_in(completed_message, ["params", "update"])
    assert update["fileOperationId"] == "dynamic-item-9"
    refute Map.has_key?(update, "callId")
    refute Map.has_key?(update, "rawInput")
    refute Map.has_key?(update, "rawOutput")
  end

  test "success false fails a file operation with a clean bounded reason" do
    state = initialized_state(%{"fs" => %{"readTextFile" => true}})
    long_reason = "  host\nread failed  " <> String.duplicate("x", 1_000)

    failed = %{
      "id" => "file-failed-item",
      "type" => "dynamicToolCall",
      "namespace" => nil,
      "tool" => "search_text_file",
      "arguments" => %{"path" => "contract.jsonl", "query" => "(인)"},
      "status" => "completed",
      "success" => false,
      "contentItems" => [%{"type" => "inputText", "text" => long_reason}],
      "durationMs" => 1
    }

    assert {:messages, [message], _state} = item_notification(state, "item/completed", failed)

    assert %{
             "sessionUpdate" => "file_operation_update",
             "fileOperationId" => "file-failed-item",
             "operation" => "search_text_file",
             "kind" => "search",
             "path" => "contract.jsonl",
             "query" => "(인)",
             "status" => "failed",
             "reason" => reason
           } = update = get_in(message, ["params", "update"])

    assert String.starts_with?(reason, "host read failed x")
    assert String.ends_with?(reason, "…")
    assert String.length(reason) == 500
    refute reason =~ "\n"

    assert Map.keys(update) |> Enum.sort() ==
             expected_file_operation_keys("search_text_file", true)
  end

  test "ordinary dynamic tool notifications still emit ACP tool updates" do
    state = initialized_state(%{})

    started = %{
      "id" => "ordinary-item",
      "type" => "dynamicToolCall",
      "namespace" => nil,
      "tool" => "custom_lookup",
      "arguments" => %{"query" => "contract"},
      "status" => "inProgress",
      "contentItems" => nil,
      "success" => nil,
      "durationMs" => nil
    }

    assert {:messages, [started_message], state} =
             item_notification(state, "item/started", started)

    assert %{
             "sessionUpdate" => "tool_call",
             "toolCallId" => "ordinary-item",
             "title" => "custom_lookup"
           } = get_in(started_message, ["params", "update"])

    failed =
      started
      |> Map.put("status", "failed")
      |> Map.put("error", %{"message" => "lookup failed"})

    assert {:messages, [failed_message], _state} =
             item_notification(state, "item/completed", failed)

    assert %{
             "sessionUpdate" => "tool_call_update",
             "toolCallId" => "ordinary-item",
             "toolName" => "custom_lookup",
             "status" => "failed"
           } = get_in(failed_message, ["params", "update"])
  end

  test "MCP tool notifications remain visible when their tool name resembles a file operation" do
    state = initialized_state(%{})

    started = %{
      "id" => "mcp-item",
      "type" => "mcpToolCall",
      "server" => "doc",
      "tool" => "read_text_file",
      "arguments" => %{"path" => "contract.jsonl"},
      "status" => "inProgress"
    }

    assert {:messages, [started_message], state} =
             item_notification(state, "item/started", started)

    assert %{
             "sessionUpdate" => "tool_call",
             "toolCallId" => "mcp-item",
             "title" => "read_text_file"
           } = get_in(started_message, ["params", "update"])

    completed =
      started
      |> Map.put("status", "completed")
      |> Map.put("result", %{"Ok" => %{"content" => [%{"text" => "done"}]}})

    assert {:messages, [completed_message], _state} =
             item_notification(state, "item/completed", completed)

    assert %{
             "sessionUpdate" => "tool_call_update",
             "toolCallId" => "mcp-item",
             "toolName" => "read_text_file",
             "status" => "completed"
           } = get_in(completed_message, ["params", "update"])
  end

  test "edit_text_file performs exact replacements between ACP read and host write" do
    state =
      initialized_state(%{"fs" => %{"readTextFile" => true, "writeTextFile" => true}})

    assert {:messages, [read_request], state} =
             dynamic_call(state, 43, "edit_text_file", %{
               "path" => ".ecrits/mount/contract.jsonl",
               "edits" => [
                 %{"old_text" => "계약명: 빈칸", "new_text" => "계약명: 접근성 진단"},
                 %{"old_text" => "금액: 빈칸", "new_text" => "금액: 88,000,000원"}
               ]
             })

    assert {:messages, [write_request], state} =
             Codex.translate_outbound(
               %{
                 "id" => read_request["id"],
                 "result" => %{"content" => "계약명: 빈칸\n금액: 빈칸\n"}
               },
               state
             )

    assert write_request["method"] == "fs/write_text_file"

    assert write_request["params"]["content"] ==
             "계약명: 접근성 진단\n금액: 88,000,000원\n"

    expected_sha256 =
      :crypto.hash(:sha256, "계약명: 빈칸\n금액: 빈칸\n")
      |> Base.encode16(case: :lower)

    assert write_request["params"]["expectedSha256"] == expected_sha256

    assert {:ok, response, _state} =
             Codex.translate_outbound(
               %{"id" => write_request["id"], "result" => %{}},
               state
             )

    assert get_in(decode(response), ["result", "success"]) == true

    assert get_in(decode(response), ["result", "contentItems", Access.at(0), "text"]) ==
             "Applied 2 exact replacement(s) through ACP."
  end

  test "edit_text_file rejects an ambiguous replacement without writing" do
    state =
      initialized_state(%{"fs" => %{"readTextFile" => true, "writeTextFile" => true}})

    assert {:messages, [read_request], state} =
             dynamic_call(state, 44, "edit_text_file", %{
               "path" => "contract.jsonl",
               "edits" => [%{"old_text" => "미기재", "new_text" => "값"}]
             })

    assert {:ok, response, state} =
             Codex.translate_outbound(
               %{
                 "id" => read_request["id"],
                 "result" => %{"content" => "미기재\n미기재\n"}
               },
               state
             )

    assert get_in(decode(response), ["result", "success"]) == false

    assert get_in(decode(response), ["result", "contentItems", Access.at(0), "text"]) =~
             "matched 2 times"

    assert state.pending_client_requests == %{}
  end

  test "does not expose file tools when the ACP client omitted filesystem capabilities" do
    state = initialized_state(%{})

    assert {:ok, request, _state} =
             Codex.translate_outbound(
               %{"method" => "session/new", "id" => 1, "params" => %{"cwd" => "/workspace"}},
               state
             )

    refute get_in(decode(request), ["params", "dynamicTools"])
  end

  test "serializes edits for one path and drops late replies after cancellation" do
    state =
      initialized_state(%{"fs" => %{"readTextFile" => true, "writeTextFile" => true}})

    assert {:messages, [read_request], state} =
             dynamic_call(state, 50, "edit_text_file", %{
               "path" => "contract.jsonl",
               "edits" => [%{"old_text" => "old", "new_text" => "first"}]
             })

    assert {:skip_and_write, response, state} =
             dynamic_call(state, 51, "edit_text_file", %{
               "path" => "contract.jsonl",
               "edits" => [%{"old_text" => "old", "new_text" => "second"}]
             })

    assert get_in(decode(response), ["result", "success"]) == false

    assert get_in(decode(response), ["result", "contentItems", Access.at(0), "text"]) =~
             "already in progress"

    assert {:ok, :skip, state} =
             Codex.translate_outbound(
               %{"method" => "session/cancel", "params" => %{}},
               state
             )

    assert state.pending_client_requests == %{}

    assert {:ok, :skip, _state} =
             Codex.translate_outbound(
               %{
                 "id" => read_request["id"],
                 "result" => %{"content" => "old"}
               },
               state
             )
  end

  test "keeps the editor tool schema stable when the current handler is read-only" do
    state = initialized_state(%{"fs" => %{"readTextFile" => true}})

    assert {:ok, request, _state} =
             Codex.translate_outbound(
               %{"method" => "session/new", "id" => 1, "params" => %{"cwd" => "/workspace"}},
               state
             )

    names =
      request
      |> decode()
      |> get_in(["params", "dynamicTools"])
      |> Enum.map(& &1["name"])

    assert names == ["read_text_file", "search_text_file", "edit_text_file"]

    assert {:skip_and_write, response, _state} =
             dynamic_call(state, 52, "edit_text_file", %{
               "path" => "contract.jsonl",
               "edits" => [%{"old_text" => "old", "new_text" => "new"}]
             })

    assert get_in(decode(response), ["result", "success"]) == false

    assert get_in(decode(response), ["result", "contentItems", Access.at(0), "text"]) =~
             "writeTextFile"
  end

  defp initialized_state(capabilities) do
    {:ok, state} = Codex.init([])

    {:ok, :skip, state} =
      Codex.translate_outbound(
        %{"method" => "initialize", "params" => %{"clientCapabilities" => capabilities}},
        state
      )

    state
  end

  defp dynamic_call(state, id, tool, arguments) do
    Codex.translate_inbound(
      Jason.encode!(%{
        "id" => id,
        "method" => "item/tool/call",
        "params" => %{
          "threadId" => "thread-1",
          "turnId" => "turn-1",
          "callId" => "dynamic-call-#{id}",
          "namespace" => nil,
          "tool" => tool,
          "arguments" => arguments
        }
      }),
      state
    )
  end

  defp item_notification(state, method, item) do
    Codex.translate_inbound(
      Jason.encode!(%{"method" => method, "params" => %{"item" => item}}),
      state
    )
  end

  defp expected_file_operation_keys(operation, failed?) do
    keys =
      ~w(fileOperationId kind operation path sessionUpdate status) ++
        if(operation == "search_text_file", do: ["query"], else: []) ++
        if(failed?, do: ["reason"], else: [])

    Enum.sort(keys)
  end

  defp decode(iodata), do: iodata |> IO.iodata_to_binary() |> Jason.decode!()
end
