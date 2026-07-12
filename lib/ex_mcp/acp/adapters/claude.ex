defmodule ExMCP.ACP.Adapters.Claude do
  @moduledoc """
  Adapter for Claude Code CLI.

  Translates between ACP JSON-RPC and Claude's stream-json NDJSON protocol.
  Ported from Arbor's `CliTransport` + `StreamParser`.

  ## Claude CLI Protocol

  - **Input:** NDJSON on stdin with `{"type":"user","message":{...},"session_id":"..."}`
  - **Output:** NDJSON on stdout with event types: `stream_event`, `assistant`, `user`, `result`
  - **Args:** `--output-format stream-json --input-format stream-json --verbose`

  ## ACP Mapping

  | Claude Event | ACP Message |
  |---|---|
  | `stream_event` (text_delta) | `session/update` notification (text) |
  | `stream_event` (thinking_delta) | `session/update` (`agent_thought_chunk`) |
  | `assistant` | accumulate content blocks |
  | `assistant` (tool_use) | `session/update` (`tool_call`) |
  | `user` (tool_result) | `session/update` (`tool_call_update`) |
  | `result` | prompt response result |

  ## Features

  - Session resume via `--resume <session_id>` flag
  - Thinking block streaming with deduplication
  - Multi-turn tool use cycle tracking
  - Usage tracking with cache token support
  - Configurable thinking budget

  ## Limitations

  - No session persistence/listing (sessions managed by Claude CLI)
  - No mode switching (Claude CLI uses `--dangerously-skip-permissions`)
  - No session cancel (would need SIGINT to Port subprocess)
  - No runtime config changes (static at launch)
  """

  @behaviour ExMCP.ACP.Adapter

  require Logger

  # Stop reason classification matching Zed's error semantics
  @stop_reasons %{
    "end_turn" => "end_turn",
    "stop" => "end_turn",
    "max_tokens" => "max_tokens",
    "tool_use" => "tool_use",
    "error" => "error"
  }

  defstruct [
    :session_id,
    :model,
    :cwd,
    text_acc: [],
    thinking_acc: [],
    thinking_blocks: [],
    current_block_type: nil,
    usage: nil,
    pending_prompt_id: nil,
    in_tool_use: false,
    opts: []
  ]

  # Adapter callbacks

  @impl true
  def init(opts) do
    {:ok, %__MODULE__{opts: opts, cwd: Keyword.get(opts, :cwd)}}
  end

  @impl true
  def command(opts) do
    thinking_budget = Keyword.get(opts, :max_thinking_tokens, 10_000)

    args = [
      "--output-format",
      "stream-json",
      "--input-format",
      "stream-json",
      "--verbose",
      "--max-thinking-tokens",
      to_string(thinking_budget),
      "--dangerously-skip-permissions",
      # Isolate the embedded agent from the USER's global Claude Code config.
      # Without this the CLI loads ~/.claude settings: SessionStart hooks,
      # plugins, skills, deferred-tool listings and global MCP servers all leak
      # into every ACP turn — observed stalling a real turn for 9+ min when the
      # model chased the host harness's ToolSearch meta-tool instead of the
      # caller's MCP tools. Keychain/OAuth auth is unaffected (credentials are
      # not a settings source). Only the --mcp-config servers we pass exist.
      "--setting-sources",
      "",
      "--strict-mcp-config",
      "--disable-slash-commands"
    ]

    args = append_optional(args, opts, :model, "--model")
    args = append_optional(args, opts, :system_prompt, "--system-prompt")

    # Forward MCP servers so the agent can discover + call them. Claude CLI loads
    # MCP servers from `--mcp-config <json>` at launch (the published package
    # dropped this); we synthesize the `{"mcpServers": {...}}` JSON here.
    args = append_mcp_config(args, Keyword.get(opts, :mcp_servers))

    # Session resume
    args =
      case Keyword.get(opts, :session_id) do
        nil -> args
        id -> args ++ ["--resume", id]
      end

    cli_path = Keyword.get(opts, :cli_path, "claude")
    {cli_path, args}
  end

  defp append_mcp_config(args, servers) when is_list(servers) and servers != [] do
    mcp_servers =
      servers
      |> Enum.map(&normalize_mcp_server/1)
      |> Enum.reduce(%{}, fn server, acc ->
        case mcp_server_entry(server) do
          nil -> acc
          {name, entry} -> Map.put(acc, name, entry)
        end
      end)

    if map_size(mcp_servers) == 0 do
      args
    else
      args ++ ["--mcp-config", Jason.encode!(%{"mcpServers" => mcp_servers})]
    end
  end

  defp append_mcp_config(args, _servers), do: args

  defp normalize_mcp_server(%{} = server) do
    %{
      name: to_string(server["name"] || server[:name] || "mcp"),
      url: server["url"] || server[:url],
      command: server["command"] || server[:command],
      args: server["args"] || server[:args]
    }
  end

  defp mcp_server_entry(%{name: name, url: url}) when is_binary(url) and url != "" do
    {name, %{"type" => "http", "url" => url}}
  end

  defp mcp_server_entry(%{name: name, command: command} = server)
       when is_binary(command) and command != "" do
    entry =
      %{"type" => "stdio", "command" => command}
      |> maybe_put_args(server[:args])

    {name, entry}
  end

  defp mcp_server_entry(_server), do: nil

  defp maybe_put_args(entry, args) when is_list(args) and args != [],
    do: Map.put(entry, "args", args)

  defp maybe_put_args(entry, _args), do: entry

  @impl true
  def capabilities do
    %{
      "_meta" => %{"streaming" => true}
      # Note: Claude CLI supports plan mode via --allowedTools but we don't
      # expose mode switching through the adapter. Session modes would require
      # the bridge to restart the subprocess with different flags.
    }
  end

  @impl true
  def config_options do
    []
  end

  # ── Outbound: ACP → Claude CLI ───────────────────────────────

  @impl true
  def translate_outbound(%{"method" => "initialize"}, state) do
    # Initialize is synthesized by the bridge
    {:ok, :skip, state}
  end

  def translate_outbound(%{"method" => "session/new"}, state) do
    # Claude doesn't have explicit session creation — session starts on first prompt
    {:ok, :skip, state}
  end

  def translate_outbound(%{"method" => "session/load"}, state) do
    # Session resume is handled via --resume flag at startup.
    # To resume a session, pass session_id in adapter_opts when creating the bridge.
    {:ok, :skip, state}
  end

  def translate_outbound(
        %{"method" => "session/prompt", "id" => id, "params" => params},
        state
      ) do
    content = extract_prompt_text(params["prompt"])
    session_id = params["sessionId"] || state.session_id || "default"

    stdin_msg = %{
      "type" => "user",
      "message" => %{"role" => "user", "content" => content},
      "session_id" => session_id
    }

    data = Jason.encode!(stdin_msg) <> "\n"

    state = reset_accumulators(%{state | pending_prompt_id: id, session_id: session_id})
    {:ok, data, state}
  end

  def translate_outbound(%{"method" => "session/cancel"}, state) do
    # Cancel would need SIGINT — not directly supported via Port.command.
    # The bridge would need to send OS signal to the Port subprocess.
    # For now, log and skip.
    Logger.debug("[Claude Adapter] session/cancel not supported (requires SIGINT)")
    {:ok, :skip, state}
  end

  # Explicit handlers for ACP methods we don't support —
  # better than silently dropping via catch-all
  def translate_outbound(%{"method" => "session/set_mode"}, state) do
    Logger.debug("[Claude Adapter] session/set_mode not supported (static permissions)")
    {:ok, :skip, state}
  end

  # ACP spec: session/set_config_option — store model for reference
  def translate_outbound(
        %{"method" => "session/set_config_option", "params" => %{"configId" => "model"} = params},
        state
      ) do
    state = %{state | model: params["value"]}

    Logger.debug(
      "[Claude Adapter] Model preference stored: #{params["value"]} (static at startup)"
    )

    {:ok, :skip, state}
  end

  def translate_outbound(%{"method" => "session/set_config_option"}, state) do
    {:ok, :skip, state}
  end

  def translate_outbound(_msg, state) do
    {:ok, :skip, state}
  end

  # ── Inbound: Claude CLI → ACP ─────────────────────────────────

  @impl true
  def translate_inbound(line, state) do
    trimmed = String.trim(line)

    case Jason.decode(trimmed) do
      {:ok, event} ->
        process_event(event, state)

      {:error, _} ->
        {:skip, state}
    end
  end

  # Event processing — ported from Arbor.AI.StreamParser

  defp process_event(%{"type" => "stream_event", "event" => event}, state) do
    process_stream_event(event, state)
  end

  defp process_event(%{"type" => "assistant", "message" => message}, state) do
    process_assistant_message(message, state)
  end

  defp process_event(%{"type" => "user", "message" => message}, state) do
    # Tool results from Claude CLI's internal tool use.
    # Emit a session update for observability, but don't affect text accumulation.
    notifications = extract_tool_results(message, state)

    case notifications do
      [] -> {:skip, state}
      notifs -> {:messages, notifs, state}
    end
  end

  defp process_event(%{"type" => "result"} = result, state) do
    process_result(result, state)
  end

  # System/status events from Claude CLI.
  #
  # Claude CLI's stream-json `system` events are keyed by a `subtype` field
  # (NOT a `message` field) — `init`, `api_retry`, `compact_boundary`, … The
  # prior implementation only matched `event["message"]`, so EVERY real system
  # event (which has `subtype`, not `message`) fell through to `{:skip, state}`
  # and was silently dropped — including `api_retry`, the CLI's own
  # rate-limit/transient-error backoff signal. Dispatch on `subtype` instead.
  defp process_event(%{"type" => "system", "subtype" => subtype} = event, state) do
    process_system_subtype(subtype, event, state)
  end

  # Older/alternate shape: a `system` event that carries a free-form `message`
  # instead of a `subtype`. Preserve the original behavior for that case.
  defp process_event(%{"type" => "system", "message" => message}, state)
       when not is_nil(message) do
    notification =
      session_update(state.session_id, %{
        "sessionUpdate" => "status",
        "status" => "info",
        "message" => message
      })

    {:messages, [notification], state}
  end

  defp process_event(%{"type" => "system"}, state), do: {:skip, state}

  # Rate limit events
  defp process_event(%{"type" => "rate_limit_event"} = event, state) do
    notification =
      session_update(state.session_id, %{
        "sessionUpdate" => "status",
        "status" => "rate_limited",
        "retryAfter" => event["retry_after"]
      })

    {:messages, [notification], state}
  end

  # Catch-all for unrecognized top-level events. The prior version dropped these
  # SILENTLY (no log), so a new content-bearing Claude CLI message type would
  # vanish with no breadcrumb. Log at :debug so it's an intentional, traceable
  # pass-through. Streaming/lifecycle subtypes (message_start/delta/stop) are
  # already intentionally skipped in `process_stream_event/2`; the authoritative
  # usage + stop_reason arrive in the `result` event.
  defp process_event(event, state) do
    Logger.debug("[Claude Adapter] Skipping unhandled event type: #{inspect(event["type"])}")
    {:skip, state}
  end

  # ── system subtype handlers ───────────────────────────────────

  # `init`: session bootstrap — carries session_id, model, available tools,
  # mcp_servers. Capture session_id/model into state (so subsequent updates and
  # the final result use the right session id) and surface an informational
  # status so the UI can show which model/MCP servers the turn is running with.
  defp process_system_subtype("init", event, state) do
    state =
      state
      |> maybe_set(:session_id, event["session_id"])
      |> maybe_set(:model, event["model"])

    notification =
      session_update(state.session_id, %{
        "sessionUpdate" => "status",
        "status" => "info",
        "subtype" => "init",
        "model" => event["model"],
        "mcpServers" => event["mcp_servers"]
      })

    {:messages, [notification], state}
  end

  # `api_retry`: the CLI hit a transient/rate-limit error and is backing off.
  # Previously dropped entirely (it has `subtype`, not `message`). Surface it as
  # a `rate_limited` status carrying the retry metadata so the UI can show the
  # backoff instead of appearing frozen.
  defp process_system_subtype("api_retry", event, state) do
    notification =
      session_update(state.session_id, %{
        "sessionUpdate" => "status",
        "status" => "rate_limited",
        "subtype" => "api_retry",
        "attempt" => event["attempt"],
        "maxRetries" => event["max_retries"],
        "retryAfter" => event["retry_delay_ms"],
        "errorStatus" => event["error_status"],
        "message" => event["error"]
      })

    {:messages, [notification], state}
  end

  # `compact_boundary`: the CLI auto-compacted the context window mid-session.
  defp process_system_subtype("compact_boundary", event, state) do
    notification =
      session_update(state.session_id, %{
        "sessionUpdate" => "status",
        "status" => "compacting",
        "subtype" => "compact_boundary",
        "trigger" => event["compact_metadata"]["trigger"] || event["trigger"]
      })

    {:messages, [notification], state}
  rescue
    # `compact_metadata` shape varies / may be absent across CLI versions — never
    # let a missing key crash the turn; emit the status without the trigger.
    _ ->
      {:messages,
       [
         session_update(state.session_id, %{
           "sessionUpdate" => "status",
           "status" => "compacting",
           "subtype" => "compact_boundary"
         })
       ], state}
  end

  # `thinking_tokens`: periodic heartbeat while the model is in extended
  # thinking (no content deltas stream during this phase). Previously dropped —
  # which made a long thinking phase indistinguishable from a stalled turn, so
  # idle-based ACP timeouts killed genuinely active design turns. Surface it as
  # a `thinking` status: consumers register activity and UIs can show progress.
  defp process_system_subtype("thinking_tokens", event, state) do
    notification =
      session_update(state.session_id, %{
        "sessionUpdate" => "status",
        "status" => "thinking",
        "subtype" => "thinking_tokens",
        "tokens" => event["tokens"] || event["thinking_tokens"] || event["token_count"]
      })

    {:messages, [notification], state}
  end

  # Any other system subtype: intentional, traceable skip (not a silent drop).
  defp process_system_subtype(subtype, _event, state) do
    Logger.debug("[Claude Adapter] Skipping system subtype: #{inspect(subtype)}")
    {:skip, state}
  end

  # Stream events produce ACP session/update notifications

  defp process_stream_event(
         %{"type" => "content_block_start", "content_block" => block},
         state
       ) do
    block_type = block_type_from(block)
    {:skip, %{state | current_block_type: block_type}}
  end

  defp process_stream_event(%{"type" => "content_block_delta", "delta" => delta}, state) do
    process_delta(delta, state)
  end

  defp process_stream_event(%{"type" => "content_block_stop"}, state) do
    state = finalize_current_block(state)
    {:skip, state}
  end

  # Other stream subtypes (message_start, message_delta, message_stop). These
  # carry incremental stop_reason/usage that we don't need here — the `result`
  # event provides the authoritative usage and stop_reason. Intentional skip,
  # logged at :debug as a breadcrumb (was a silent drop).
  defp process_stream_event(event, state) do
    Logger.debug("[Claude Adapter] Skipping stream subtype: #{inspect(event["type"])}")
    {:skip, state}
  end

  defp process_delta(%{"type" => "text_delta", "text" => text}, state) do
    state = %{state | text_acc: [text | state.text_acc]}

    notification =
      session_update(state.session_id, %{
        "sessionUpdate" => "agent_message_chunk",
        "content" => %{"type" => "text", "text" => text}
      })

    {:messages, [notification], state}
  end

  defp process_delta(%{"type" => "thinking_delta", "thinking" => thinking}, state) do
    state = %{
      state
      | thinking_acc: [thinking | state.thinking_acc],
        current_block_type: :thinking
    }

    notification =
      session_update(state.session_id, %{
        "sessionUpdate" => "agent_thought_chunk",
        "content" => %{"type" => "text", "text" => thinking}
      })

    {:messages, [notification], state}
  end

  defp process_delta(_delta, state) do
    {:skip, state}
  end

  # Assistant message — accumulate thinking/text blocks, emit tool_call notifications

  defp process_assistant_message(%{"content" => content} = message, state)
       when is_list(content) do
    session_id = message["id"]
    model = message["model"]

    has_tool_use = Enum.any?(content, &(&1["type"] == "tool_use"))
    has_text = Enum.any?(content, &(&1["type"] == "text"))

    # When a new assistant message arrives after tool use with text content,
    # clear the previous text accumulator so we capture the final answer
    state =
      if state.in_tool_use and has_text do
        %{state | text_acc: [], in_tool_use: false}
      else
        state
      end

    {state, notifications} = process_content_blocks(content, state)

    state =
      state
      |> maybe_set(:session_id, session_id)
      |> maybe_set(:model, model)

    # Mark that we're in a tool use cycle
    state = if has_tool_use, do: %{state | in_tool_use: true}, else: state

    case notifications do
      [] -> {:skip, state}
      notifs -> {:messages, notifs, state}
    end
  end

  defp process_assistant_message(_message, state), do: {:skip, state}

  defp process_content_blocks(content, state) when is_list(content) do
    Enum.reduce(content, {state, []}, fn block, {st, notifs} ->
      {new_st, new_notifs} = process_content_block(block, st)
      {new_st, notifs ++ new_notifs}
    end)
  end

  defp process_content_block(%{"type" => "thinking"} = block, state) do
    thinking_block = %{
      type: :thinking,
      text: block["thinking"] || "",
      signature: block["signature"]
    }

    # Dedup: only add if not already from streaming
    state =
      if Enum.any?(state.thinking_blocks, &(&1.text == thinking_block.text)) do
        state
      else
        %{state | thinking_blocks: [thinking_block | state.thinking_blocks]}
      end

    {state, []}
  end

  defp process_content_block(%{"type" => "text", "text" => text}, state)
       when is_binary(text) do
    # Accumulate text from assistant message when streaming deltas were absent
    state =
      if state.text_acc == [] do
        %{state | text_acc: [text]}
      else
        state
      end

    # Emit as agent_message_chunk for streaming visibility
    notification =
      session_update(state.session_id, %{
        "sessionUpdate" => "agent_message_chunk",
        "content" => %{"type" => "text", "text" => text}
      })

    {state, [notification]}
  end

  defp process_content_block(%{"type" => "tool_use"} = block, state) do
    # Claude CLI is calling one of its own tools (Grep, Read, Write, etc.)
    tool_name = block["name"] || "tool"
    input = block["input"] || %{}

    # Build full tool info matching Zed's toolInfoFromToolUse pattern
    tool_info = tool_info_from_use(tool_name, input, block["id"], state.cwd)

    update =
      %{
        "sessionUpdate" => "tool_call_update",
        "title" => tool_info.title,
        "toolCallId" => block["id"],
        "toolName" => tool_name,
        "kind" => tool_info.kind,
        "status" => "in_progress",
        "input" => input
      }
      |> maybe_put_tool("content", non_empty_list(tool_info.content))
      |> maybe_put_tool("locations", non_empty_list(tool_info.locations))

    notification = session_update(state.session_id, update)

    {state, [notification]}
  end

  defp process_content_block(_block, state), do: {state, []}

  # Result event — finalize and produce ACP prompt response

  defp process_result(result, state) do
    usage = extract_usage(result)
    session_id = result["session_id"] || state.session_id

    text =
      case state.text_acc do
        [] ->
          # No streaming deltas received — fall back to the result event's text field.
          # Claude CLI in stream-json stdin mode may skip content_block_delta events.
          result["result"] || ""

        acc ->
          IO.iodata_to_binary(Enum.reverse(acc))
      end

    state = finalize_thinking_block(state)

    thinking =
      case state.thinking_blocks do
        [] -> nil
        blocks -> Enum.reverse(blocks)
      end

    state = %{state | usage: usage, session_id: session_id}

    # Build ACP response messages
    messages = []

    # Usage update notification (emit before final result so clients can display it)
    messages = [
      session_update(session_id, %{
        "sessionUpdate" => "usage",
        "inputTokens" => usage.input_tokens,
        "outputTokens" => usage.output_tokens,
        "cacheReadTokens" => usage.cache_read_tokens,
        "cacheCreationTokens" => usage.cache_creation_tokens
      })
      | messages
    ]

    # Status update
    messages = [
      session_update(session_id, %{"sessionUpdate" => "status", "status" => "completed"})
      | messages
    ]

    # If we have a pending prompt ID, send the result
    messages =
      if state.pending_prompt_id do
        stop_reason = classify_stop_reason(result)

        response_result = %{
          "stopReason" => stop_reason,
          "text" => text,
          "usage" => format_usage(usage)
        }

        response_result =
          if thinking do
            thinking_data =
              Enum.map(thinking, fn block ->
                %{"text" => block.text, "signature" => block[:signature]}
              end)

            Map.put(response_result, "thinking", thinking_data)
          else
            response_result
          end

        response = %{
          "jsonrpc" => "2.0",
          "result" => response_result,
          "id" => state.pending_prompt_id
        }

        [response | messages]
      else
        messages
      end

    state = %{state | pending_prompt_id: nil}
    {:messages, Enum.reverse(messages), state}
  end

  # ── Helpers ────────────────────────────────────────────────────

  defp block_type_from(%{"type" => "thinking"}), do: :thinking
  defp block_type_from(%{"type" => "text"}), do: :text
  defp block_type_from(_), do: :text

  defp finalize_current_block(%{current_block_type: :thinking} = state) do
    finalize_thinking_block(state)
  end

  defp finalize_current_block(state) do
    %{state | current_block_type: nil}
  end

  defp finalize_thinking_block(%{thinking_acc: []} = state) do
    %{state | current_block_type: nil}
  end

  defp finalize_thinking_block(state) do
    text = IO.iodata_to_binary(Enum.reverse(state.thinking_acc))

    block = %{type: :thinking, text: text, signature: nil}

    %{
      state
      | thinking_blocks: [block | state.thinking_blocks],
        thinking_acc: [],
        current_block_type: nil
    }
  end

  defp extract_tool_results(%{"content" => content}, state) when is_list(content) do
    content
    |> Enum.filter(&(&1["type"] == "tool_result"))
    |> Enum.map(fn result ->
      is_error = result["is_error"] || false

      # Use spec-compliant tool_call_update with completed/failed status
      update = %{
        "sessionUpdate" => "tool_call_update",
        "toolCallId" => result["tool_use_id"],
        "status" => if(is_error, do: "failed", else: "completed"),
        "content" => parse_tool_result_content(result["content"]),
        "isError" => is_error
      }

      session_update(state.session_id, update)
    end)
  end

  defp extract_tool_results(_, _state), do: []

  defp reset_accumulators(state) do
    %{
      state
      | text_acc: [],
        thinking_acc: [],
        thinking_blocks: [],
        current_block_type: nil,
        usage: nil,
        in_tool_use: false
    }
  end

  defp extract_usage(result) do
    raw = result["usage"] || %{}

    %{
      input_tokens: raw["input_tokens"] || 0,
      output_tokens: raw["output_tokens"] || 0,
      cache_read_tokens: raw["cache_read_input_tokens"] || 0,
      cache_creation_tokens: raw["cache_creation_input_tokens"] || 0
    }
  end

  defp format_usage(usage) do
    %{
      "inputTokens" => usage.input_tokens,
      "outputTokens" => usage.output_tokens,
      "cacheReadTokens" => usage.cache_read_tokens,
      "cacheCreationTokens" => usage.cache_creation_tokens
    }
  end

  # Classify stop reason with more granularity than binary error/success
  defp classify_stop_reason(result) do
    cond do
      result["is_error"] ->
        "error"

      result["stop_reason"] ->
        Map.get(@stop_reasons, result["stop_reason"], result["stop_reason"])

      # Check for max tokens by examining the result text
      result["usage"] && result["usage"]["output_tokens"] &&
          result["usage"]["output_tokens"] >= (result["usage"]["max_output_tokens"] || 999_999) ->
        "max_tokens"

      true ->
        "end_turn"
    end
  end

  # ── Tool Introspection ──────────────────────────────────────────
  # Mirrors Zed's toolInfoFromToolUse pattern: parse tool_use inputs to produce
  # structured title, kind, content (diffs/terminal), and locations (file:line).
  # All data comes from the same CLI NDJSON — no special SDK access needed.

  # Tool kinds matching ACP ToolKind enum
  @tool_kinds %{
    "Read" => "read",
    "Write" => "edit",
    "Edit" => "edit",
    "Bash" => "execute",
    "Grep" => "search",
    "Glob" => "search",
    "WebFetch" => "search",
    "WebSearch" => "search",
    "Agent" => "think",
    "Task" => "think",
    "TodoRead" => "read",
    "TodoWrite" => "edit",
    "NotebookEdit" => "edit"
  }

  defp tool_info_from_use("Read", input, _id, cwd) do
    path = input["file_path"]
    display = display_path(path, cwd)
    line_suffix = format_line_suffix(input)

    %{
      title: "Read #{display}#{line_suffix}",
      kind: "read",
      content: [],
      locations:
        if(path,
          do: [%{"path" => path, "line" => input["offset"] || 1}],
          else: []
        )
    }
  end

  defp tool_info_from_use("Write", input, _id, cwd) do
    path = input["file_path"]
    display = display_path(path, cwd)

    %{
      title: "Write #{display}",
      kind: "edit",
      content:
        if(path && input["content"],
          do: [
            %{"type" => "diff", "path" => path, "oldText" => nil, "newText" => input["content"]}
          ],
          else: []
        ),
      locations: if(path, do: [%{"path" => path, "line" => 1}], else: [])
    }
  end

  defp tool_info_from_use("Edit", input, _id, cwd) do
    path = input["file_path"]
    display = display_path(path, cwd)

    %{
      title: "Edit #{display}",
      kind: "edit",
      content:
        if(path && input["old_string"] && input["new_string"],
          do: [
            %{
              "type" => "diff",
              "path" => path,
              "oldText" => input["old_string"],
              "newText" => input["new_string"]
            }
          ],
          else: []
        ),
      locations: if(path, do: [%{"path" => path, "line" => 1}], else: [])
    }
  end

  defp tool_info_from_use("Bash", input, id, _cwd) do
    command = input["command"] || ""

    %{
      title: if(command != "", do: truncate(command, 60), else: "Terminal"),
      kind: "execute",
      content: [%{"type" => "terminal", "terminalId" => id}],
      locations: []
    }
  end

  defp tool_info_from_use("Grep", input, _id, _cwd) do
    pattern = input["pattern"] || ""

    %{
      title: "Search: #{truncate(pattern, 40)}",
      kind: "search",
      content:
        if(pattern != "",
          do: [%{"type" => "content", "content" => %{"type" => "text", "text" => pattern}}],
          else: []
        ),
      locations: []
    }
  end

  defp tool_info_from_use("Glob", input, _id, _cwd) do
    pattern = input["pattern"] || ""

    %{
      title: "Find: #{truncate(pattern, 40)}",
      kind: "search",
      content: [],
      locations: []
    }
  end

  defp tool_info_from_use("WebFetch", input, _id, _cwd) do
    url = input["url"] || ""

    %{
      title: "Fetch: #{truncate(url, 50)}",
      kind: "search",
      content:
        if(url != "",
          do: [%{"type" => "content", "content" => %{"type" => "text", "text" => url}}],
          else: []
        ),
      locations: []
    }
  end

  defp tool_info_from_use("WebSearch", input, _id, _cwd) do
    query = input["query"] || ""

    %{
      title: "Search: #{truncate(query, 40)}",
      kind: "search",
      content: [],
      locations: []
    }
  end

  defp tool_info_from_use("Agent", input, _id, _cwd) do
    desc = input["description"] || input["prompt"] || "Task"

    %{
      title: truncate(desc, 60),
      kind: "think",
      content:
        if(input["prompt"],
          do: [
            %{"type" => "content", "content" => %{"type" => "text", "text" => input["prompt"]}}
          ],
          else: []
        ),
      locations: []
    }
  end

  defp tool_info_from_use("Task", input, id, cwd),
    do: tool_info_from_use("Agent", input, id, cwd)

  defp tool_info_from_use(name, _input, _id, _cwd) do
    %{
      title: name,
      kind: Map.get(@tool_kinds, name, "other"),
      content: [],
      locations: []
    }
  end

  # Convert absolute path to project-relative for display
  defp display_path(nil, _cwd), do: "File"

  defp display_path(path, cwd) when is_binary(path) and is_binary(cwd) do
    resolved_cwd = Path.expand(cwd)

    if String.starts_with?(path, resolved_cwd <> "/") do
      Path.relative_to(path, resolved_cwd)
    else
      Path.basename(path)
    end
  end

  defp display_path(path, _cwd) when is_binary(path), do: Path.basename(path)

  defp format_line_suffix(%{"limit" => limit, "offset" => offset})
       when is_integer(limit) and limit > 0 and is_integer(offset) do
    " (#{offset}-#{offset + limit - 1})"
  end

  defp format_line_suffix(%{"offset" => offset}) when is_integer(offset) and offset > 1 do
    " (from line #{offset})"
  end

  defp format_line_suffix(_), do: ""

  # Parse tool result content for structured display
  defp parse_tool_result_content(content) when is_list(content) do
    Enum.map_join(content, "\n", fn
      %{"type" => "text", "text" => text} -> text
      %{"text" => text} -> text
      other -> inspect(other)
    end)
  end

  defp parse_tool_result_content(content) when is_binary(content), do: content
  defp parse_tool_result_content(nil), do: ""
  defp parse_tool_result_content(other), do: inspect(other)

  defp truncate(str, max) when is_binary(str) and byte_size(str) > max do
    String.slice(str, 0, max) <> "..."
  end

  defp truncate(str, _max) when is_binary(str), do: str
  defp truncate(_, _), do: ""

  defp non_empty_list([]), do: nil
  defp non_empty_list(list), do: list

  defp maybe_put_tool(map, _key, nil), do: map
  defp maybe_put_tool(map, key, value), do: Map.put(map, key, value)

  defp session_update(session_id, update) do
    %{
      "jsonrpc" => "2.0",
      "method" => "session/update",
      "params" => %{
        "sessionId" => session_id || "default",
        "update" => update
      }
    }
  end

  defp extract_prompt_text(nil), do: ""

  defp extract_prompt_text(blocks) when is_list(blocks) do
    blocks
    |> Enum.filter(&(&1["type"] == "text"))
    |> Enum.map_join("\n", &(&1["text"] || ""))
  end

  defp extract_prompt_text(text) when is_binary(text), do: text

  defp maybe_set(state, _key, nil), do: state
  defp maybe_set(state, key, value), do: Map.put(state, key, value)

  defp append_optional(args, opts, key, flag) do
    case Keyword.get(opts, key) do
      nil -> args
      value -> args ++ [flag, to_string(value)]
    end
  end
end
