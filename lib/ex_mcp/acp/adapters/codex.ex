defmodule ExMCP.ACP.Adapters.Codex do
  @moduledoc """
  Adapter for Codex CLI (OpenAI) using `codex app-server` persistent mode.

  Translates between ACP JSON-RPC and Codex's app-server JSON-RPC protocol.
  The app-server runs as a persistent subprocess communicating over NDJSON
  on stdin/stdout, with a JSON-RPC initialize handshake.

  Ported from `nshkrdotcom/codex_sdk`'s `AppServer.Connection` pattern.

  ## Codex App-Server Protocol

  - **Command:** `codex app-server`
  - **Handshake:** `initialize` request → response → `initialized` notification
  - **Session:** `thread/start` → `turn/start` → notifications → `turn/completed`
  - **Notifications:** NDJSON events for items, text deltas, reasoning, tool calls, etc.

  ## ACP Mapping

  | ACP Message | Codex JSON-RPC |
  |---|---|
  | `session/new` | `thread/start` request |
  | `session/load` | `thread/start` with threadId (resume) |
  | `session/prompt` | `turn/start` request |
  | `session/cancel` | `turn/interrupt` request |
  | `item/agentMessage/delta` | `session/update` (text) |
  | `item/reasoning/textDelta` | `session/update` (`agent_thought_chunk`) |
  | `item/completed` (tool) | `session/update` (`tool_call_update`) |
  | `item/commandExecution/*` | `session/update` (`tool_call` / `tool_call_update`) |
  | `turn/completed` | prompt response result |

  ## Features

  - Initialize handshake with `post_connect/1`
  - Text and thinking streaming
  - Tool call and tool result notifications
  - Command execution output streaming
  - Token usage tracking
  - Turn interrupt/cancel support
  - Image content in prompts

  ## Limitations

  - No session listing (Codex doesn't expose session enumeration)
  - No mode switching (static approval policy at session start)
  - No model switching mid-session (set at thread/start)
  - No authentication flow (relies on user's local auth)
  """

  @behaviour ExMCP.ACP.Adapter

  require Logger

  # Seconds codex waits for an HTTP MCP server to finish its initial connect +
  # `tools/list` before proceeding with the turn. Generous on purpose so the
  # in-process doc server is RELIABLY ready (and its `doc.*` tools in context)
  # rather than racing the first turn. See `mcp_server_overrides/1`.
  @mcp_startup_timeout_sec 30
  # Seconds an individual MCP tool call may run before codex aborts it; doc.edit
  # on a large document can be slow, so give it room.
  @mcp_tool_timeout_sec 120

  defstruct [
    :model,
    :thread_id,
    :turn_id,
    :current_prompt_acp_id,
    next_id: 1,
    phase: :initializing,
    pending_requests: %{},
    accumulated_text: [],
    accumulated_thinking: [],
    accumulated_usage: nil,
    auto_approve?: false,
    opts: []
  ]

  # Adapter callbacks

  @impl true
  def init(opts) do
    {:ok,
     %__MODULE__{
       opts: opts,
       model: Keyword.get(opts, :model),
       auto_approve?: auto_approve?(opts)
     }}
  end

  # Codex 0.137 sends server→client JSON-RPC *requests* (not notifications) when a
  # tool wants approval / an MCP server elicits input — e.g.
  # `mcpServer/elicitation/request`, `item/commandExecution/requestApproval`,
  # `item/fileChange/requestApproval`. The app-server BLOCKS the turn until the
  # client replies; if we never answer, a write tool (like `doc.edit`) stalls and
  # the turn ends without applying the edit. When the workspace access mode permits
  # writes (no per-write approval), we auto-approve these so the edit goes through
  # unattended, mirroring how a human would click "approve". This is gated on the
  # access mode the LiveView passes down (`approvalPolicy`/`sandbox`).
  defp auto_approve?(opts) do
    policy = opts |> Keyword.get(:approvalPolicy) |> to_string()
    sandbox = opts |> Keyword.get(:sandbox) |> to_string()

    # "never" approval policy == full-workspace (don't ask). A writable sandbox
    # (workspace-write / danger-full-access) likewise means writes are intended.
    policy in ["never"] or sandbox in ["workspace-write", "danger-full-access"]
  end

  @impl true
  def command(opts) do
    # Forward MCP servers to the codex app-server as `-c` config overrides so the
    # agent can discover + call them. Codex configures MCP servers at the
    # app-server process level (TOML `[mcp_servers.<name>]`), not per thread/start,
    # so they must be injected here at launch.
    mcp_args = mcp_server_config_args(Keyword.get(opts, :mcp_servers))
    {"codex", ["app-server"] ++ mcp_args}
  end

  # Build `-c key=value` overrides for each MCP server. HTTP (streamable) servers
  # use `mcp_servers.<name>.url`; stdio servers use `.command`/`.args`. We also
  # enable `features.rmcp_client` which codex 0.137 requires for HTTP (streamable)
  # MCP transport — the in-process doc server is served over HTTP.
  defp mcp_server_config_args(servers) when is_list(servers) and servers != [] do
    base = ["-c", "features.rmcp_client=true"]

    Enum.reduce(servers, base, fn server, acc ->
      acc ++ mcp_server_overrides(normalize_mcp_server(server))
    end)
  end

  defp mcp_server_config_args(_servers), do: []

  defp mcp_server_overrides(%{name: name, url: url}) when is_binary(url) and url != "" do
    # `startup_timeout_sec`/`tool_timeout_sec` are per-server keys on codex's
    # `RawMcpServerConfig` (verified against `codex app-server --strict-config`
    # on 0.137). Codex connects to an HTTP (streamable) MCP server asynchronously
    # and only surfaces its tools to the model once the connection is established
    # and `tools/list` returns. With a short/default startup window, a slow first
    # connect to the in-process doc server can race the turn: the model is handed
    # ZERO `doc.*` tools, then hallucinates that "편집 MCP가 로드되지 않았습니다"
    # and flails with codex's built-in MCP-listing tools instead of calling
    # `doc.*`. A generous startup timeout makes codex WAIT for the doc server's
    # tool list before the turn begins, so the tools are surfaced in context.
    # `tool_timeout_sec` likewise gives the (sometimes slow) doc.edit call room to
    # finish instead of being aborted mid-write. This is the deterministic config
    # lever available here — `tool_search` is already removed/disabled by default
    # on 0.137, so there is no per-server "always_available" toggle to flip; a
    # generous eager-startup window is the closest equivalent.
    [
      "-c",
      "mcp_servers.#{name}.url=#{toml_string(url)}",
      "-c",
      "mcp_servers.#{name}.startup_timeout_sec=#{@mcp_startup_timeout_sec}",
      "-c",
      "mcp_servers.#{name}.tool_timeout_sec=#{@mcp_tool_timeout_sec}"
    ]
  end

  defp mcp_server_overrides(%{name: name, command: command} = server)
       when is_binary(command) and command != "" do
    args =
      case server[:args] do
        list when is_list(list) and list != [] ->
          ["-c", "mcp_servers.#{name}.args=#{toml_array(list)}"]

        _ ->
          []
      end

    ["-c", "mcp_servers.#{name}.command=#{toml_string(command)}"] ++ args
  end

  defp mcp_server_overrides(_server), do: []

  defp normalize_mcp_server(%{} = server) do
    %{
      name: to_string(server["name"] || server[:name] || "mcp"),
      url: server["url"] || server[:url],
      command: server["command"] || server[:command],
      args: server["args"] || server[:args]
    }
  end

  defp toml_string(value), do: "\"" <> String.replace(to_string(value), "\"", "\\\"") <> "\""

  defp toml_array(list) do
    "[" <> Enum.map_join(list, ",", &toml_string/1) <> "]"
  end

  @impl true
  def capabilities do
    %{
      "promptCapabilities" => %{"image" => true},
      "loadSession" => true,
      "sessionCapabilities" => %{"resume" => %{}}
      # Note: Codex supports approval policies (suggest/auto-edit/full-auto)
      # but these are set at thread/start, not switched dynamically.
    }
  end

  @impl true
  def modes do
    [
      %{
        "id" => "suggest",
        "name" => "Suggest",
        "description" => "Suggests changes, requires approval for each"
      },
      %{
        "id" => "auto-edit",
        "name" => "Auto Edit",
        "description" => "Automatically applies code changes"
      },
      %{
        "id" => "full-auto",
        "name" => "Full Auto",
        "description" => "Full autonomy including shell commands"
      }
    ]
  end

  @impl true
  def config_options do
    []
  end

  @impl true
  def post_connect(state) do
    {id, state} = next_request_id(state)

    client_name = Keyword.get(state.opts, :client_name, "ex_mcp")
    client_version = Keyword.get(state.opts, :client_version, "1.0.0")

    request =
      encode_request(id, "initialize", %{
        "clientInfo" => %{
          "name" => client_name,
          "version" => client_version
        }
      })

    state = track_request(state, id, :initialize, nil)
    {:ok, request, state}
  end

  # ── Outbound: ACP → Codex ────────────────────────────────────

  @impl true
  def translate_outbound(%{"method" => "initialize"}, state) do
    # Handled by post_connect + bridge synthetic init
    {:ok, :skip, state}
  end

  def translate_outbound(
        %{"method" => "session/new", "id" => acp_id, "params" => params},
        state
      ) do
    {id, state} = next_request_id(state)

    wire_params =
      %{}
      |> maybe_put("model", state.model || params["model"])
      |> maybe_put("cwd", params["cwd"] || Keyword.get(state.opts, :cwd))
      |> maybe_put("approvalPolicy", params["approvalPolicy"])
      |> maybe_put("sandbox", params["sandbox"])

    request = encode_request(id, "thread/start", wire_params)
    state = track_request(state, id, :thread_start, acp_id)
    {:ok, request, state}
  end

  def translate_outbound(
        %{"method" => "session/load", "id" => acp_id, "params" => params},
        state
      ) do
    # Resume an existing thread. Codex's `thread/start` does NOT resume when
    # handed a `threadId` (it always begins a fresh thread, losing history) —
    # the dedicated `thread/resume` method (codex app-server 0.137+) is what
    # rejoins the rollout and carries the prior conversation forward. This is
    # what gives the chat agent cross-turn memory.
    session_id = params["sessionId"]

    if session_id do
      {id, state} = next_request_id(state)

      wire_params =
        %{"threadId" => session_id}
        |> maybe_put("model", state.model || params["model"])
        |> maybe_put("cwd", params["cwd"] || Keyword.get(state.opts, :cwd))

      request = encode_request(id, "thread/resume", wire_params)
      state = track_request(state, id, :thread_start, acp_id)
      {:ok, request, state}
    else
      {:ok, :skip, state}
    end
  end

  def translate_outbound(
        %{"method" => "session/resume", "id" => acp_id, "params" => params},
        state
      ) do
    translate_outbound(%{"method" => "session/load", "id" => acp_id, "params" => params}, state)
  end

  def translate_outbound(
        %{"method" => "session/prompt", "id" => acp_id, "params" => params},
        state
      ) do
    thread_id = params["sessionId"] || state.thread_id

    if thread_id do
      {id, state} = next_request_id(state)

      # Build input items from prompt content
      input = extract_input_items(params["prompt"])

      wire_params =
        %{
          "threadId" => thread_id,
          "input" => input
        }
        |> maybe_put("model", params["model"] || state.model)
        |> maybe_put("cwd", params["cwd"] || Keyword.get(state.opts, :cwd))

      request = encode_request(id, "turn/start", wire_params)

      state =
        state
        |> track_request(id, :turn_start, acp_id)
        |> Map.put(:accumulated_text, [])
        |> Map.put(:accumulated_thinking, [])
        |> Map.put(:accumulated_usage, nil)

      {:ok, request, state}
    else
      {:ok, :skip, state}
    end
  end

  def translate_outbound(
        %{"method" => "session/cancel", "params" => params},
        state
      ) do
    thread_id = params["sessionId"] || state.thread_id
    turn_id = params["turnId"] || state.turn_id

    if thread_id && turn_id do
      {id, state} = next_request_id(state)

      request =
        encode_request(id, "turn/interrupt", %{
          "threadId" => thread_id,
          "turnId" => turn_id
        })

      state = track_request(state, id, :turn_interrupt, nil)
      {:ok, request, state}
    else
      {:ok, :skip, state}
    end
  end

  # ACP spec: session/set_mode — Codex uses approvalPolicy at thread/start
  # We track it in state for the next thread/start call
  def translate_outbound(%{"method" => "session/set_mode", "params" => params}, state) do
    Logger.debug(
      "[Codex Adapter] Mode change stored: #{params["modeId"]} (applies on next session)"
    )

    {:ok, :skip, state}
  end

  def translate_outbound(%{"method" => "session/set_mode"}, state) do
    {:ok, :skip, state}
  end

  # ACP spec: session/set_config_option — model stored for next turn
  def translate_outbound(
        %{"method" => "session/set_config_option", "params" => %{"configId" => "model"} = params},
        state
      ) do
    state = %{state | model: params["value"]}
    {:ok, :skip, state}
  end

  def translate_outbound(%{"method" => "session/set_config_option"}, state) do
    {:ok, :skip, state}
  end

  def translate_outbound(_msg, state) do
    {:ok, :skip, state}
  end

  # ── Inbound: Codex → ACP ─────────────────────────────────────

  @impl true
  def translate_inbound(line, state) do
    case Jason.decode(line) do
      {:ok, msg} ->
        handle_inbound_message(msg, state)

      {:error, _} ->
        {:skip, state}
    end
  end

  # JSON-RPC message routing

  defp handle_inbound_message(%{"id" => id, "result" => result}, state) do
    handle_response(state, id, {:ok, result})
  end

  defp handle_inbound_message(%{"id" => id, "error" => error}, state) do
    handle_response(state, id, {:error, error})
  end

  # Server→client *request* (has BOTH an id and a method): codex app-server is
  # blocking on our reply. These are the approval/elicitation prompts that gate
  # write tools. Must be matched BEFORE the notification clause below, since a
  # notification has a method but no id.
  defp handle_inbound_message(%{"id" => id, "method" => method} = msg, state)
       when is_binary(method) do
    handle_server_request(method, id, msg["params"] || %{}, state)
  end

  defp handle_inbound_message(%{"method" => method, "params" => params}, state)
       when is_binary(method) do
    handle_notification(method, params || %{}, state)
  end

  defp handle_inbound_message(%{"method" => method}, state) when is_binary(method) do
    handle_notification(method, %{}, state)
  end

  defp handle_inbound_message(_msg, state) do
    {:skip, state}
  end

  # ── Response Handling ─────────────────────────────────────────

  defp handle_response(state, id, reply) do
    case Map.pop(state.pending_requests, id) do
      {nil, _} ->
        {:skip, state}

      {%{type: type} = entry, pending} ->
        state = %{state | pending_requests: pending}
        handle_typed_response(type, entry, reply, state)
    end
  end

  defp handle_typed_response(:initialize, _entry, _reply, state) do
    state = %{state | phase: :ready}
    initialized = encode_notification("initialized")
    {:skip_and_write, initialized, state}
  end

  defp handle_typed_response(:thread_start, %{acp_id: acp_id}, {:ok, result}, state) do
    thread = result["thread"] || %{}
    thread_id = thread["id"] || ""
    state = %{state | thread_id: thread_id}

    response = %{
      "jsonrpc" => "2.0",
      "id" => acp_id,
      "result" => %{"sessionId" => thread_id, "metadata" => thread}
    }

    {:messages, [response], state}
  end

  defp handle_typed_response(:thread_start, %{acp_id: acp_id}, {:error, error}, state) do
    {:messages, [error_response(acp_id, error)], state}
  end

  defp handle_typed_response(:turn_start, %{acp_id: acp_id}, {:ok, result}, state) do
    turn = result["turn"] || %{}
    turn_id = turn["id"] || ""
    {:skip, %{state | turn_id: turn_id, current_prompt_acp_id: acp_id}}
  end

  defp handle_typed_response(:turn_start, %{acp_id: acp_id}, {:error, error}, state) do
    {:messages, [error_response(acp_id, error)], state}
  end

  defp handle_typed_response(:turn_interrupt, _entry, _reply, state) do
    {:skip, state}
  end

  defp error_response(acp_id, error) do
    %{
      "jsonrpc" => "2.0",
      "id" => acp_id,
      "error" => normalize_error(error)
    }
  end

  # ── Server→Client Request Handling (approvals / elicitations) ──
  #
  # These are JSON-RPC *requests* the codex app-server sends DOWN to us and then
  # blocks on, waiting for a result. The shapes come from the codex app-server
  # protocol (`codex app-server generate-ts`, `ServerRequest`):
  #
  #   mcpServer/elicitation/request   -> { action: "accept"|"decline"|"cancel", content, _meta }
  #   item/fileChange/requestApproval -> { decision: "accept"|"acceptForSession"|"decline"|"cancel" }
  #   item/commandExecution/requestApproval -> { decision: "accept"|... }
  #   item/permissions/requestApproval-> { permissions, scope }  (not auto-handled; declined)
  #   applyPatchApproval / execCommandApproval (legacy v1) -> { decision: ReviewDecision }
  #
  # When the workspace access mode permits writes we auto-approve so the write
  # tool (e.g. doc.edit) proceeds; otherwise we decline (the user picked a
  # read-only / ask mode and we don't have an interactive approval UI wired here).
  defp handle_server_request("mcpServer/elicitation/request", id, params, state) do
    # MCP elicitation: accept with empty structured content (our doc.* tools don't
    # require structured user input — the elicitation is just an approval gate).
    # This is the exact request codex 0.137 sends before running an MCP *write*
    # tool, e.g. "Allow the doc MCP server to run tool \"doc.edit\"?", with
    # `_meta.codex_approval_kind = "mcp_tool_call"`. It blocks the turn until we
    # reply — leaving it unanswered is what stalls doc.edit.
    {action, content} =
      if state.auto_approve?, do: {"accept", %{}}, else: {"decline", nil}

    Logger.debug(
      "[Codex Adapter] mcpServer/elicitation/request -> #{action} (#{params["serverName"]})"
    )

    {:skip_and_write, jsonrpc_result(id, %{"action" => action, "content" => content, "_meta" => nil}),
     state}
  end

  defp handle_server_request(method, id, _params, state)
       when method in ["item/fileChange/requestApproval", "item/commandExecution/requestApproval"] do
    decision = if state.auto_approve?, do: "accept", else: "decline"
    Logger.debug("[Codex Adapter] #{method} -> #{decision}")
    {:skip_and_write, jsonrpc_result(id, %{"decision" => decision}), state}
  end

  # Legacy v1 approval requests use the `ReviewDecision` enum ("approved"/"denied").
  defp handle_server_request(method, id, _params, state)
       when method in ["applyPatchApproval", "execCommandApproval"] do
    decision = if state.auto_approve?, do: "approved", else: "denied"
    Logger.debug("[Codex Adapter] #{method} -> #{decision}")
    {:skip_and_write, jsonrpc_result(id, %{"decision" => decision}), state}
  end

  # Any other server request we don't explicitly model: reply with a JSON-RPC
  # error so the app-server stops blocking (rather than hanging the turn forever).
  defp handle_server_request(method, id, _params, state) do
    Logger.debug("[Codex Adapter] Unhandled server request: #{method} (replying method_not_found)")

    error = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => -32_601, "message" => "method not handled: #{method}"}
    }

    {:skip_and_write, [Jason.encode!(error), "\n"], state}
  end

  defp jsonrpc_result(id, result) do
    [Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result}), "\n"]
  end

  # ── Notification Handling ─────────────────────────────────────

  defp handle_notification("thread/started", params, state) do
    thread = params["thread"] || %{}
    thread_id = thread["id"] || ""
    {:skip, %{state | thread_id: thread_id}}
  end

  defp handle_notification("turn/started", params, state) do
    turn = params["turn"] || %{}
    turn_id = turn["id"] || ""
    {:skip, %{state | turn_id: turn_id}}
  end

  # ── Text Streaming ───────────────────────────────────────────

  defp handle_notification("item/agentMessage/delta", params, state) do
    delta = params["delta"] || ""
    state = %{state | accumulated_text: [delta | state.accumulated_text]}

    notification =
      session_update(state, %{
        "sessionUpdate" => "agent_message_chunk",
        "content" => %{"type" => "text", "text" => delta}
      })

    {:messages, [notification], state}
  end

  # ── Thinking/Reasoning Streaming ──────────────────────────────

  defp handle_notification("item/reasoning/textDelta", params, state) do
    delta = params["delta"] || ""
    state = %{state | accumulated_thinking: [delta | state.accumulated_thinking]}

    notification =
      session_update(state, %{
        "sessionUpdate" => "agent_thought_chunk",
        "content" => %{"type" => "text", "text" => delta}
      })

    {:messages, [notification], state}
  end

  # ── Tool Call Notifications ───────────────────────────────────

  # Tool call started (item/created with tool call type)
  defp handle_notification(
         "item/created",
         %{"item" => %{"type" => "function_call"} = item},
         state
       ) do
    notification =
      session_update(state, %{
        "sessionUpdate" => "tool_call",
        "toolCallId" => item["callId"] || item["id"],
        "title" => item["name"],
        "kind" => codex_tool_kind(item["name"]),
        "rawInput" => item["arguments"],
        "status" => "pending"
      })

    {:messages, [notification], state}
  end

  defp handle_notification("item/created", _params, state) do
    {:skip, state}
  end

  # Codex 0.137 renamed the start notification `item/created` -> `item/started`
  # and the tool item type `function_call` -> `mcpToolCall` (for MCP servers) /
  # `functionCall` (built-in). An MCP call starts as:
  #
  #   item/started %{"item" => %{"type" => "mcpToolCall", "id" => "call_...",
  #     "server" => "ecrits_doc", "tool" => "doc.list", "arguments" => %{},
  #     "status" => "inProgress", "result" => nil}}
  #
  # Surface it as an ACP `tool_call` so the chat-rail tool_call block opens.
  defp handle_notification("item/started", %{"item" => %{"type" => "mcpToolCall"} = item}, state) do
    {:messages, [mcp_tool_call_started_update(state, item)], state}
  end

  defp handle_notification("item/started", %{"item" => %{"type" => "functionCall"} = item}, state) do
    notification =
      session_update(state, %{
        "sessionUpdate" => "tool_call",
        "toolCallId" => item["callId"] || item["id"],
        "title" => item["name"],
        "kind" => codex_tool_kind(item["name"]),
        "rawInput" => item["arguments"],
        "status" => "pending"
      })

    {:messages, [notification], state}
  end

  defp handle_notification("item/started", _params, state) do
    {:skip, state}
  end

  # Item completed — handles agent messages, tool calls, and tool results
  defp handle_notification("item/completed", params, state) do
    item = params["item"] || %{}
    handle_item_completed(item, state)
  end

  # ── Command Execution Streaming ───────────────────────────────

  defp handle_notification("item/commandExecution/started", params, state) do
    notification =
      session_update(state, %{
        "sessionUpdate" => "tool_call",
        "toolCallId" => params["callId"] || params["itemId"],
        "title" => command_title(params["command"]),
        "kind" => "execute",
        "status" => "in_progress",
        "rawInput" => %{"command" => params["command"]}
      })

    {:messages, [notification], state}
  end

  defp handle_notification("item/commandExecution/outputDelta", params, state) do
    delta = params["delta"] || ""

    notification =
      session_update(state, %{
        "sessionUpdate" => "tool_call_update",
        "toolCallId" => params["callId"] || params["itemId"] || params["item_id"],
        "content" => [tool_text_content(delta)]
      })

    {:messages, [notification], state}
  end

  defp handle_notification("item/commandExecution/completed", params, state) do
    notification =
      session_update(state, %{
        "sessionUpdate" => "tool_call_update",
        "status" => "completed",
        "toolCallId" => params["callId"] || params["itemId"],
        "rawOutput" => %{
          "exitCode" => params["exitCode"],
          "output" => params["output"]
        },
        "content" => [tool_text_content(params["output"] || "")]
      })

    {:messages, [notification], state}
  end

  # ── Patch/Approval Events ─────────────────────────────────────

  defp handle_notification("item/patch/created", params, state) do
    patch = params["patch"] || params

    notification =
      session_update(state, %{
        "sessionUpdate" => "tool_call",
        "toolCallId" => patch["id"] || params["itemId"],
        "title" => "Edit File",
        "kind" => "edit",
        "rawInput" => %{
          "path" => patch["path"],
          "diff" => patch["diff"]
        },
        "status" => "pending"
      })

    {:messages, [notification], state}
  end

  # ── Turn Completion ───────────────────────────────────────────

  defp handle_notification("turn/completed", params, state) do
    turn = params["turn"] || %{}
    status = turn["status"]

    # Use saved ACP ID (set when turn/start response arrived)
    acp_id = state.current_prompt_acp_id

    text =
      state.accumulated_text
      |> Enum.reverse()
      |> IO.iodata_to_binary()

    messages = []

    # Emit usage update if we have accumulated usage
    messages =
      if state.accumulated_usage do
        [
          session_update(state, %{
            "sessionUpdate" => "usage",
            "content" => state.accumulated_usage
          })
          | messages
        ]
      else
        messages
      end

    # Status completed notification
    messages = [
      session_update(state, %{
        "sessionUpdate" => "status",
        "status" => "completed"
      })
      | messages
    ]

    # Prompt response
    messages =
      if acp_id do
        response = %{
          "jsonrpc" => "2.0",
          "id" => acp_id,
          "result" => %{
            "stopReason" => normalize_stop_reason(status),
            "text" => text,
            "sessionId" => state.thread_id,
            "turnId" => state.turn_id
          }
        }

        [response | messages]
      else
        messages
      end

    state = %{
      state
      | accumulated_text: [],
        accumulated_thinking: [],
        accumulated_usage: nil,
        turn_id: nil,
        current_prompt_acp_id: nil
    }

    {:messages, Enum.reverse(messages), state}
  end

  # ── Token Usage ───────────────────────────────────────────────

  defp handle_notification("thread/tokenUsage/updated", params, state) do
    token_usage = params["tokenUsage"] || %{}
    total = token_usage["total"] || %{}

    usage_data = %{
      "inputTokens" => total["inputTokens"] || 0,
      "outputTokens" => total["outputTokens"] || 0,
      "cachedInputTokens" => total["cachedInputTokens"] || 0
    }

    # Accumulate usage for turn/completed response
    state = %{state | accumulated_usage: usage_data}

    notification =
      session_update(state, %{
        "sessionUpdate" => "usage",
        "content" => usage_data
      })

    {:messages, [notification], state}
  end

  # ── Error Notifications ───────────────────────────────────────

  defp handle_notification("error", params, state) do
    error = params["error"] || %{}

    notification =
      session_update(state, %{
        "sessionUpdate" => "error",
        "content" => error["message"] || "Unknown error",
        "code" => error["code"]
      })

    {:messages, [notification], state}
  end

  # ── Web Search Events ─────────────────────────────────────────

  defp handle_notification("item/webSearch/started", params, state) do
    notification =
      session_update(state, %{
        "sessionUpdate" => "tool_call",
        "toolCallId" => params["itemId"],
        "title" => "Web Search",
        "kind" => "fetch",
        "status" => "in_progress",
        "rawInput" => %{"query" => params["query"]}
      })

    {:messages, [notification], state}
  end

  defp handle_notification("item/webSearch/completed", params, state) do
    notification =
      session_update(state, %{
        "sessionUpdate" => "tool_call_update",
        "status" => "completed",
        "toolCallId" => params["itemId"],
        "rawOutput" => params["results"],
        "content" => [tool_text_content(format_web_search_results(params["results"]))]
      })

    {:messages, [notification], state}
  end

  # Catch-all for unknown notifications
  defp handle_notification(method, _params, state) do
    Logger.debug("[Codex Adapter] Unhandled notification: #{method}")
    {:skip, state}
  end

  # ── Item Completion Handlers ───────────────────────────────────

  # Codex 0.137 MCP tool result: the same `mcpToolCall` item, now with
  # `status: "completed"|"failed"` and a populated `result`/`error`.
  defp handle_item_completed(%{"type" => "mcpToolCall"} = item, state) do
    failed? = item["status"] == "failed" or item["error"] != nil
    output = mcp_tool_result_text(item)

    notification =
      session_update(state, %{
        "sessionUpdate" => "tool_call_update",
        "toolCallId" => item["id"] || item["callId"],
        "toolName" => mcp_tool_name(item),
        "status" => if(failed?, do: "failed", else: "completed"),
        "kind" => codex_tool_kind(item["tool"]),
        "rawInput" => item["arguments"],
        "rawOutput" => item["result"] || item["error"],
        "content" => [tool_text_content(output)]
      })

    {:messages, [notification], state}
  end

  defp handle_item_completed(%{"type" => "functionCall"} = item, state) do
    failed? = item["status"] == "failed" or item["error"] != nil

    notification =
      session_update(state, %{
        "sessionUpdate" => "tool_call_update",
        "toolCallId" => item["callId"] || item["id"],
        "toolName" => item["name"],
        "status" => if(failed?, do: "failed", else: "completed"),
        "kind" => codex_tool_kind(item["name"]),
        "rawInput" => item["arguments"],
        "rawOutput" => item["output"] || item["result"],
        "content" => [tool_text_content(item["output"] || item["result"] || "")]
      })

    {:messages, [notification], state}
  end

  defp handle_item_completed(%{"type" => "agentMessage"} = item, state) do
    text = item["text"] || ""

    notification =
      session_update(state, %{
        "sessionUpdate" => "agent_message_chunk",
        "content" => %{"type" => "text", "text" => text},
        "final" => true
      })

    {:messages, [notification], state}
  end

  defp handle_item_completed(%{"type" => "agent_message"} = item, state) do
    text = item["text"] || ""

    notification =
      session_update(state, %{
        "sessionUpdate" => "agent_message_chunk",
        "content" => %{"type" => "text", "text" => text},
        "final" => true
      })

    {:messages, [notification], state}
  end

  defp handle_item_completed(%{"type" => "function_call"} = item, state) do
    notification =
      session_update(state, %{
        "sessionUpdate" => "tool_call_update",
        "toolCallId" => item["callId"] || item["id"],
        "status" => "completed",
        "kind" => codex_tool_kind(item["name"]),
        "rawInput" => item["arguments"]
      })

    {:messages, [notification], state}
  end

  defp handle_item_completed(%{"type" => "function_call_output"} = item, state) do
    notification =
      session_update(state, %{
        "sessionUpdate" => "tool_call_update",
        "toolCallId" => item["callId"] || item["id"],
        "status" => if(item["isError"], do: "failed", else: "completed"),
        "content" => [tool_text_content(item["output"] || item["text"] || "")],
        "rawOutput" => item["output"] || item["text"] || ""
      })

    {:messages, [notification], state}
  end

  defp handle_item_completed(%{"type" => "patch"} = item, state) do
    notification =
      session_update(state, %{
        "sessionUpdate" => "tool_call_update",
        "toolCallId" => item["callId"] || item["id"],
        "kind" => "edit",
        "status" => "completed",
        "content" => [tool_diff_content(item["path"], item["diff"] || item["text"] || "")]
      })

    {:messages, [notification], state}
  end

  defp handle_item_completed(_item, state), do: {:skip, state}

  # ── Helpers ────────────────────────────────────────────────────

  defp next_request_id(%{next_id: id} = state) do
    {id, %{state | next_id: id + 1}}
  end

  defp track_request(state, id, type, acp_id) do
    entry = %{type: type, acp_id: acp_id}
    %{state | pending_requests: Map.put(state.pending_requests, id, entry)}
  end

  defp tool_text_content(text) do
    %{
      "type" => "content",
      "content" => %{"type" => "text", "text" => to_string(text || "")}
    }
  end

  defp tool_diff_content(path, new_text) do
    %{
      "type" => "diff",
      "path" => path || "",
      "oldText" => nil,
      "newText" => to_string(new_text || "")
    }
  end

  defp command_title(command) when is_binary(command) and command != "", do: command
  defp command_title(_), do: "Run Command"

  defp codex_tool_kind(name) when is_binary(name) do
    name = String.downcase(name)

    cond do
      String.contains?(name, ["read", "view", "open"]) -> "read"
      String.contains?(name, ["write", "edit", "patch", "update"]) -> "edit"
      String.contains?(name, ["delete", "remove"]) -> "delete"
      String.contains?(name, ["move", "rename"]) -> "move"
      String.contains?(name, ["search", "grep", "find"]) -> "search"
      String.contains?(name, ["exec", "command", "bash", "shell"]) -> "execute"
      String.contains?(name, ["think", "reason"]) -> "think"
      String.contains?(name, ["fetch", "web"]) -> "fetch"
      true -> "other"
    end
  end

  defp codex_tool_kind(_), do: "other"

  # ── MCP tool-call (Codex 0.137 `mcpToolCall` item) helpers ──────

  defp mcp_tool_call_started_update(state, item) do
    session_update(state, %{
      "sessionUpdate" => "tool_call",
      "toolCallId" => item["id"] || item["callId"],
      "toolName" => mcp_tool_name(item),
      "title" => mcp_tool_name(item),
      "kind" => codex_tool_kind(item["tool"]),
      "rawInput" => item["arguments"],
      "status" => "in_progress"
    })
  end

  # `server`/`tool` are split in the item (e.g. "doc" + "doc.list"). The `tool`
  # field is already the dotted server-side tool name, so re-prefixing it with
  # the MCP server registration name would yield a redundant "doc.doc.list".
  # Present the bare dotted tool name (e.g. "doc.list") for the chat rail.
  defp mcp_tool_name(%{"tool" => tool}) when is_binary(tool), do: tool
  defp mcp_tool_name(%{"server" => server}) when is_binary(server), do: server
  defp mcp_tool_name(%{"name" => name}) when is_binary(name), do: name
  defp mcp_tool_name(_item), do: "mcp_tool"

  # Codex wraps the MCP result as `%{"Ok" => %{"content" => [...]}}` (or
  # `%{"Err" => ...}`); flatten the text content for the chat-rail block.
  defp mcp_tool_result_text(%{"result" => result}) when not is_nil(result),
    do: mcp_result_text(result)

  defp mcp_tool_result_text(%{"error" => error}) when not is_nil(error),
    do: mcp_result_text(error)

  defp mcp_tool_result_text(_item), do: ""

  defp mcp_result_text(%{"Ok" => ok}), do: mcp_result_text(ok)
  defp mcp_result_text(%{"Err" => err}), do: mcp_result_text(err)

  defp mcp_result_text(%{"content" => content}) when is_list(content) do
    content
    |> Enum.map(fn
      %{"text" => text} when is_binary(text) -> text
      other -> Jason.encode!(other)
    end)
    |> Enum.join("\n")
  end

  defp mcp_result_text(value) when is_binary(value), do: value
  defp mcp_result_text(value), do: Jason.encode!(value)

  defp format_web_search_results(results) when is_binary(results), do: results
  defp format_web_search_results(nil), do: ""
  defp format_web_search_results(results), do: Jason.encode!(results)

  defp encode_request(id, method, params) do
    params = if is_map(params) and map_size(params) > 0, do: params, else: %{}
    msg = %{"id" => id, "method" => method, "params" => params}
    [Jason.encode!(msg), "\n"]
  end

  defp encode_notification(method, params \\ nil) do
    msg =
      %{"method" => method}
      |> maybe_put("params", params)

    [Jason.encode!(msg), "\n"]
  end

  defp session_update(state, update) do
    %{
      "jsonrpc" => "2.0",
      "method" => "session/update",
      "params" => %{
        "sessionId" => state.thread_id || "default",
        "update" => update
      }
    }
  end

  # Extract input items from prompt — supports text and images
  defp extract_input_items(nil), do: [%{"type" => "text", "text" => ""}]

  defp extract_input_items(prompt) when is_binary(prompt) do
    [%{"type" => "text", "text" => prompt}]
  end

  defp extract_input_items(blocks) when is_list(blocks) do
    items =
      Enum.flat_map(blocks, fn
        %{"type" => "text", "text" => text} ->
          [%{"type" => "text", "text" => text}]

        %{"type" => "image", "data" => data} = img ->
          [
            %{
              "type" => "image",
              "data" => data,
              "mimeType" => img["mimeType"] || "image/png"
            }
          ]

        _ ->
          []
      end)

    if items == [], do: [%{"type" => "text", "text" => ""}], else: items
  end

  defp extract_input_items(_), do: [%{"type" => "text", "text" => ""}]

  defp normalize_error(%{"message" => msg} = error) do
    %{"code" => error["code"] || -1, "message" => msg}
  end

  defp normalize_error(error) when is_binary(error) do
    %{"code" => -1, "message" => error}
  end

  defp normalize_error(error) do
    %{"code" => -1, "message" => inspect(error)}
  end

  defp normalize_stop_reason(nil), do: "end_turn"
  defp normalize_stop_reason("completed"), do: "end_turn"
  defp normalize_stop_reason("cancelled"), do: "cancelled"
  defp normalize_stop_reason("interrupted"), do: "cancelled"
  defp normalize_stop_reason("errored"), do: "error"
  defp normalize_stop_reason(other), do: other

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, _key, map_val) when map_val == %{}, do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
