defmodule ExMCP.ACP.Adapters.Codex.FileLane do
  @moduledoc false

  @max_edits 100
  @tool_names ~w(read_text_file search_text_file edit_text_file)

  @doc false
  def tool_name?(name), do: name in @tool_names

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
             {:ok, path} <- required_binary(arguments, "path"),
             :ok <- validate_read_window(arguments) do
          params = %{"sessionId" => session_id, "path" => path}

          params =
            if is_integer(arguments["line"]) or is_integer(arguments["limit"]) do
              params
              |> Map.put("line", bounded_integer(arguments["line"], 1, 1, 2_000_000_000))
              |> Map.put("limit", bounded_integer(arguments["limit"], 200, 1, 2_000))
            else
              params
            end

          request =
            file_request("fs/read_text_file", params)

          {:ok, request,
           %{
             kind: :read,
             codex_id: codex_id,
             offset_chars: bounded_integer(arguments["offset"], 0, 0, 2_000_000_000),
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
        {:reply, tool_result(codex_id, true, read_chunk(content, request))}

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
        "Read a workspace text file through the host ACP client. Use offset/max_chars to page through compact one-line JSONL; line/limit are for ordinary multiline text.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string"},
          "line" => %{"type" => "integer", "minimum" => 1},
          "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 2_000},
          "offset" => %{"type" => "integer", "minimum" => 0},
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
        "Search one text file through ACP and return bounded literal occurrences with surrounding context.",
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

  defp validate_read_window(arguments) do
    if is_integer(arguments["offset"]) and
         (is_integer(arguments["line"]) or is_integer(arguments["limit"])) do
      {:error, "offset cannot be combined with line or limit"}
    else
      :ok
    end
  end

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

  defp read_chunk(content, request) do
    total_chars = String.length(content)
    offset = min(request.offset_chars, total_chars)
    chunk = String.slice(content, offset, request.max_chars)
    next_offset = offset + String.length(chunk)

    if next_offset < total_chars do
      chunk <>
        "\n[ACP chunk chars #{offset}-#{next_offset - 1} of #{total_chars}; continue with offset #{next_offset}]"
    else
      chunk
    end
  end

  defp search_text(content, query, max_results) do
    {matches, remaining_matches} =
      content
      |> bounded_literal_matches(query, max_results + 1)
      |> Enum.split(max_results)

    results =
      matches
      |> Enum.with_index(1)
      |> Enum.map_join("\n\n", fn {{offset, length}, match_number} ->
        "match #{match_number} at byte #{offset}: " <>
          matching_occurrence_snippet(content, offset, length)
      end)

    cond do
      results == "" ->
        "No literal matches."

      remaining_matches == [] ->
        results

      true ->
        results <> "\n\n[More literal matches exist; refine the query or increase max_results.]"
    end
  end

  defp bounded_literal_matches(content, query, limit),
    do: bounded_literal_matches(content, query, 0, limit, [])

  defp bounded_literal_matches(_content, _query, _offset, 0, matches),
    do: Enum.reverse(matches)

  defp bounded_literal_matches(content, query, offset, remaining, matches)
       when offset < byte_size(content) do
    case :binary.match(content, query, scope: {offset, byte_size(content) - offset}) do
      {match_offset, match_length} ->
        bounded_literal_matches(
          content,
          query,
          match_offset + match_length,
          remaining - 1,
          [{match_offset, match_length} | matches]
        )

      :nomatch ->
        Enum.reverse(matches)
    end
  end

  defp bounded_literal_matches(_content, _query, _offset, _remaining, matches),
    do: Enum.reverse(matches)

  defp matching_occurrence_snippet(content, offset, match_length) do
    content_size = byte_size(content)
    start_offset = utf8_start(content, max(offset - 1_200, 0))
    end_offset = utf8_end(content, min(offset + match_length + 1_200, content_size))
    snippet = binary_part(content, start_offset, end_offset - start_offset)

    prefix = if start_offset > 0, do: "…", else: ""
    suffix = if end_offset < content_size, do: "…", else: ""
    prefix <> snippet <> suffix
  end

  defp utf8_start(content, offset) when offset < byte_size(content) do
    if continuation_byte?(:binary.at(content, offset)),
      do: utf8_start(content, offset + 1),
      else: offset
  end

  defp utf8_start(_content, offset), do: offset

  defp utf8_end(content, offset) when offset > 0 and offset < byte_size(content) do
    if continuation_byte?(:binary.at(content, offset)),
      do: utf8_end(content, offset - 1),
      else: offset
  end

  defp utf8_end(_content, offset), do: offset

  defp continuation_byte?(byte), do: byte >= 0x80 and byte <= 0xBF

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
