defmodule ExMCP.ACP.Adapters.Codex.FileLane do
  @moduledoc false

  @max_edits 100

  def tools(capabilities) do
    if capability?(capabilities, "readTextFile") do
      [read_text_file_tool(), search_text_file_tool(), edit_text_file_tool()]
    end
  end

  def begin_call(params, codex_id, capabilities, session_id, pending)
      when is_map(params) and is_map(pending) do
    case params do
      %{"tool" => "read_text_file", "arguments" => arguments} when is_map(arguments) ->
        with :ok <- require_capability(capabilities, "readTextFile"),
             {:ok, path} <- required_binary(arguments, "path") do
          request =
            file_request(
              "fs/read_text_file",
              %{"sessionId" => session_id, "path" => path}
              |> Map.put("line", bounded_integer(arguments["line"], 1, 1, 2_000_000_000))
              |> Map.put("limit", bounded_integer(arguments["limit"], 200, 1, 2_000))
            )

          {:ok, request,
           %{
             kind: :read,
             codex_id: codex_id,
             max_chars: bounded_integer(arguments["max_chars"], 200_000, 1, 500_000)
           }}
        end

      %{"tool" => "search_text_file", "arguments" => arguments} when is_map(arguments) ->
        with :ok <- require_capability(capabilities, "readTextFile"),
             {:ok, path} <- required_binary(arguments, "path"),
             {:ok, query} <- required_binary(arguments, "query") do
          request =
            file_request("fs/read_text_file", %{
              "sessionId" => session_id,
              "path" => path
            })

          {:ok, request,
           %{
             kind: :search,
             codex_id: codex_id,
             query: query,
             max_results: bounded_integer(arguments["max_results"], 20, 1, 50)
           }}
        end

      %{"tool" => "edit_text_file", "arguments" => arguments} when is_map(arguments) ->
        with :ok <- require_capability(capabilities, "readTextFile"),
             :ok <- require_capability(capabilities, "writeTextFile"),
             {:ok, path} <- required_binary(arguments, "path"),
             :ok <- ensure_no_edit_in_flight(pending, path),
             {:ok, edits} <- required_edits(arguments["edits"]) do
          request =
            file_request("fs/read_text_file", %{
              "sessionId" => session_id,
              "path" => path
            })

          {:ok, request,
           %{
             kind: :edit_read,
             codex_id: codex_id,
             path: path,
             edits: edits,
             session_id: session_id
           }}
        end

      %{"tool" => tool} ->
        {:error, "Unsupported ACP file tool: #{inspect(tool)}"}

      _other ->
        {:error, "Malformed ACP file tool request"}
    end
  end

  def handle_response(%{kind: :read, codex_id: codex_id} = request, response) do
    case file_content(response) do
      {:ok, content} ->
        {content, truncated?} = truncate_text(content, request.max_chars)
        suffix = if truncated?, do: "\n[truncated by ACP file broker]", else: ""
        {:reply, tool_result(codex_id, true, content <> suffix)}

      {:error, reason} ->
        {:reply, tool_result(codex_id, false, reason)}
    end
  end

  def handle_response(%{kind: :search, codex_id: codex_id} = request, response) do
    case file_content(response) do
      {:ok, content} ->
        {:reply,
         tool_result(codex_id, true, search_text(content, request.query, request.max_results))}

      {:error, reason} ->
        {:reply, tool_result(codex_id, false, reason)}
    end
  end

  def handle_response(%{kind: :edit_read} = request, response) do
    with {:ok, content} <- file_content(response),
         {:ok, edited, replacement_count} <- apply_exact_edits(content, request.edits) do
      write_request =
        file_request("fs/write_text_file", %{
          "sessionId" => request.session_id,
          "path" => request.path,
          "content" => edited,
          "expectedSha256" => sha256(content)
        })

      {:request, write_request,
       %{
         kind: :edit_write,
         codex_id: request.codex_id,
         path: request.path,
         replacement_count: replacement_count
       }}
    else
      {:error, reason} -> {:reply, tool_result(request.codex_id, false, reason)}
    end
  end

  def handle_response(%{kind: :edit_write} = request, response) do
    case file_write_result(response) do
      :ok ->
        text = "Applied #{request.replacement_count} exact replacement(s) through ACP."
        {:reply, tool_result(request.codex_id, true, text)}

      {:error, reason} ->
        {:reply, tool_result(request.codex_id, false, reason)}
    end
  end

  def tool_result(id, success, text) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{
        "contentItems" => [%{"type" => "inputText", "text" => to_string(text)}],
        "success" => success
      }
    }
  end

  defp ensure_no_edit_in_flight(pending, path) do
    if Enum.any?(pending, fn {_id, request} ->
         request[:kind] in [:edit_read, :edit_write] and request[:path] == path
       end) do
      {:error, "another ACP edit is already in progress for this path"}
    else
      :ok
    end
  end

  defp read_text_file_tool do
    %{
      "type" => "function",
      "name" => "read_text_file",
      "description" =>
        "Read a workspace text file through the host ACP client. Use this instead of shell commands. Lines are 1-based and bounded.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string"},
          "line" => %{"type" => "integer", "minimum" => 1},
          "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 2_000},
          "max_chars" => %{"type" => "integer", "minimum" => 1, "maximum" => 500_000}
        },
        "required" => ["path"],
        "additionalProperties" => false
      }
    }
  end

  defp search_text_file_tool do
    %{
      "type" => "function",
      "name" => "search_text_file",
      "description" =>
        "Search one text file through ACP and return bounded matching lines. Use this instead of rg, grep, jq, or document extractors.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string"},
          "query" => %{"type" => "string", "minLength" => 1},
          "max_results" => %{"type" => "integer", "minimum" => 1, "maximum" => 50}
        },
        "required" => ["path", "query"],
        "additionalProperties" => false
      }
    }
  end

  defp edit_text_file_tool do
    %{
      "type" => "function",
      "name" => "edit_text_file",
      "description" =>
        "Apply exact code-editor-style replacements through ACP. Each non-global old_text must occur exactly once; include more context when it is ambiguous.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string"},
          "edits" => %{
            "type" => "array",
            "minItems" => 1,
            "maxItems" => @max_edits,
            "items" => %{
              "type" => "object",
              "properties" => %{
                "old_text" => %{"type" => "string", "minLength" => 1},
                "new_text" => %{"type" => "string"},
                "replace_all" => %{"type" => "boolean"}
              },
              "required" => ["old_text", "new_text"],
              "additionalProperties" => false
            }
          }
        },
        "required" => ["path", "edits"],
        "additionalProperties" => false
      }
    }
  end

  defp capability?(capabilities, capability),
    do: get_in(capabilities, ["fs", capability]) == true

  defp require_capability(capabilities, capability) do
    if capability?(capabilities, capability),
      do: :ok,
      else: {:error, "ACP client does not support fs.#{capability}"}
  end

  defp required_binary(map, key) do
    case map[key] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> {:error, "#{key} must be a non-empty string"}
    end
  end

  defp required_edits(edits)
       when is_list(edits) and edits != [] and length(edits) <= @max_edits do
    if Enum.all?(edits, fn edit ->
         is_map(edit) and is_binary(edit["old_text"]) and edit["old_text"] != "" and
           is_binary(edit["new_text"]) and is_boolean(edit["replace_all"] || false)
       end) do
      {:ok, edits}
    else
      {:error, "edits must contain old_text/new_text string pairs"}
    end
  end

  defp required_edits(_edits),
    do: {:error, "edits must contain 1 to #{@max_edits} replacements"}

  defp bounded_integer(value, default, minimum, maximum) when not is_integer(value),
    do: bounded_integer(default, default, minimum, maximum)

  defp bounded_integer(value, _default, minimum, maximum),
    do: value |> max(minimum) |> min(maximum)

  defp file_request(method, params) do
    %{
      "jsonrpc" => "2.0",
      "id" => "codex-acp-file-#{System.unique_integer([:positive, :monotonic])}",
      "method" => method,
      "params" => params
    }
  end

  defp file_content(%{"result" => %{"content" => content}}) when is_binary(content),
    do: {:ok, content}

  defp file_content(%{"error" => error}), do: {:error, client_error_message(error)}
  defp file_content(_response), do: {:error, "ACP client returned no file content"}

  defp file_write_result(%{"result" => result}) when is_map(result), do: :ok
  defp file_write_result(%{"error" => error}), do: {:error, client_error_message(error)}
  defp file_write_result(_response), do: {:error, "ACP client did not confirm the write"}

  defp client_error_message(%{"message" => message}) when is_binary(message), do: message
  defp client_error_message(error), do: inspect(error)

  defp truncate_text(text, max_chars) do
    if String.length(text) > max_chars,
      do: {String.slice(text, 0, max_chars), true},
      else: {text, false}
  end

  defp search_text(content, query, max_results) do
    matches =
      content
      |> String.split("\n", trim: false)
      |> Enum.with_index(1)
      |> Enum.filter(fn {line, _line_number} -> String.contains?(line, query) end)
      |> Enum.take(max_results)
      |> Enum.map_join("\n", fn {line, line_number} ->
        "line #{line_number}: #{matching_line_snippet(line, query)}"
      end)

    if matches == "", do: "No literal matches.", else: matches
  end

  defp matching_line_snippet(line, query) do
    case String.split(line, query, parts: 2) do
      [before, remainder] ->
        prefix = String.slice(before, max(String.length(before) - 1_000, 0), 1_000)
        suffix = String.slice(remainder, 0, 1_000)
        prefix <> query <> suffix

      _other ->
        String.slice(line, 0, 2_000)
    end
  end

  defp apply_exact_edits(content, edits) do
    Enum.reduce_while(edits, {:ok, content, 0}, fn edit, {:ok, current, total} ->
      old_text = edit["old_text"]
      new_text = edit["new_text"]
      occurrences = length(:binary.matches(current, old_text))
      replace_all? = edit["replace_all"] == true

      cond do
        old_text == new_text ->
          {:halt, {:error, "old_text and new_text must differ"}}

        occurrences == 0 ->
          {:halt, {:error, "old_text was not found"}}

        not replace_all? and occurrences != 1 ->
          {:halt,
           {:error,
            "old_text matched #{occurrences} times; include more context or set replace_all"}}

        true ->
          edited = String.replace(current, old_text, new_text, global: replace_all?)
          applied = if replace_all?, do: occurrences, else: 1
          {:cont, {:ok, edited, total + applied}}
      end
    end)
  end

  defp sha256(content),
    do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
end
