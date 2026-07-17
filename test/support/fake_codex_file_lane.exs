defmodule ExMCP.Test.FakeCodexFileLane do
  def run do
    loop(%{thread_id: "thread-file-lane", turn_id: "turn-file-lane"})
  end

  defp loop(state) do
    case IO.read(:stdio, :line) do
      :eof ->
        :ok

      {:error, _reason} ->
        :ok

      line ->
        state = line |> Jason.decode!() |> handle(state)
        loop(state)
    end
  end

  defp handle(%{"method" => "initialize", "id" => id}, state) do
    reply(id, %{"userAgent" => "fake-codex"})
    state
  end

  defp handle(%{"method" => "initialized"}, state), do: state

  defp handle(%{"method" => "thread/start", "id" => id, "params" => params}, state) do
    names = Enum.map(params["dynamicTools"] || [], & &1["name"])

    if names == ["read_text_file", "search_text_file", "edit_text_file"] do
      reply(id, %{"thread" => %{"id" => state.thread_id}})
    else
      error(id, "missing dynamic ACP file tools")
    end

    state
  end

  defp handle(%{"method" => "turn/start", "id" => id}, state) do
    reply(id, %{"turn" => %{"id" => state.turn_id}})

    notify("item/started", %{
      "item" => %{
        "id" => "dynamic-item-1",
        "type" => "dynamicToolCall",
        "namespace" => nil,
        "tool" => "read_text_file",
        "arguments" => %{"path" => "brief.md"},
        "status" => "inProgress",
        "contentItems" => nil,
        "success" => nil,
        "durationMs" => nil
      }
    })

    request(700, "item/tool/call", %{
      "threadId" => state.thread_id,
      "turnId" => state.turn_id,
      "callId" => "dynamic-call-1",
      "namespace" => nil,
      "tool" => "read_text_file",
      "arguments" => %{"path" => "brief.md"}
    })

    state
  end

  defp handle(%{"id" => 700, "result" => %{"success" => true} = result}, state) do
    notify("item/completed", %{
      "item" => %{
        "id" => "dynamic-item-1",
        "type" => "dynamicToolCall",
        "namespace" => nil,
        "tool" => "read_text_file",
        "arguments" => %{"path" => "brief.md"},
        "status" => "completed",
        "success" => true,
        "contentItems" => result["contentItems"],
        "durationMs" => 1
      }
    })

    notify("item/started", %{
      "item" => %{
        "id" => "dynamic-item-2",
        "type" => "dynamicToolCall",
        "namespace" => nil,
        "tool" => "edit_text_file",
        "arguments" => %{
          "path" => "brief.md",
          "edits" => [%{"old_text" => "brokered", "new_text" => "edited"}]
        },
        "status" => "inProgress",
        "contentItems" => nil,
        "success" => nil,
        "durationMs" => nil
      }
    })

    request(701, "item/tool/call", %{
      "threadId" => state.thread_id,
      "turnId" => state.turn_id,
      "callId" => "dynamic-call-2",
      "namespace" => nil,
      "tool" => "edit_text_file",
      "arguments" => %{
        "path" => "brief.md",
        "edits" => [%{"old_text" => "brokered", "new_text" => "edited"}]
      }
    })

    state
  end

  defp handle(%{"id" => 701, "result" => %{"success" => true} = result}, state) do
    notify("item/completed", %{
      "item" => %{
        "id" => "dynamic-item-2",
        "type" => "dynamicToolCall",
        "namespace" => nil,
        "tool" => "edit_text_file",
        "arguments" => %{
          "path" => "brief.md",
          "edits" => [%{"old_text" => "brokered", "new_text" => "edited"}]
        },
        "status" => "completed",
        "success" => true,
        "contentItems" => result["contentItems"],
        "durationMs" => 1
      }
    })

    notify("turn/completed", %{
      "turn" => %{"id" => state.turn_id, "status" => "completed"}
    })

    state
  end

  defp handle(_message, state), do: state

  defp reply(id, result), do: write(%{"jsonrpc" => "2.0", "id" => id, "result" => result})

  defp error(id, message) do
    write(%{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => -32_000, "message" => message}
    })
  end

  defp notify(method, params),
    do: write(%{"jsonrpc" => "2.0", "method" => method, "params" => params})

  defp request(id, method, params),
    do: write(%{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params})

  defp write(message), do: IO.puts(Jason.encode!(message))
end

ExMCP.Test.FakeCodexFileLane.run()
