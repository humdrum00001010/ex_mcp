defmodule ExMCP.MessageProcessor.MethodHandlers do
  @moduledoc false
  # Unified method handlers for all three server modes.
  # Each handler fetches data via the appropriate mode, then builds
  # a standard JSON-RPC response.

  require Logger

  alias ExMCP.Internal.VersionRegistry

  @default_protocol_version "2025-11-25"
  @fallback_server_info %{"name" => "ex_mcp_server", "version" => "1.0.0"}

  # --- initialize ---

  def handle_initialize(conn, handler, :direct, params, id, server_info) do
    put_success(
      conn,
      %{
        "protocolVersion" => negotiate_protocol_version(params),
        "capabilities" => deep_stringify_keys(handler.get_capabilities()),
        "serverInfo" => ensure_server_info(server_info)
      },
      id
    )
  end

  def handle_initialize(conn, server_pid, :genserver, params, id, server_info) do
    info = GenServer.call(server_pid, :get_server_info, 5000)
    capabilities = GenServer.call(server_pid, :get_capabilities, 5000)

    put_success(
      conn,
      %{
        "protocolVersion" => negotiate_protocol_version(params),
        "capabilities" => deep_stringify_keys(capabilities),
        "serverInfo" => ensure_server_info(info, server_info)
      },
      id
    )
  rescue
    error -> put_error(conn, "Initialize failed", error, id)
  end

  def handle_initialize(conn, server_pid, :handler, params, id, server_info) do
    case GenServer.call(server_pid, {:initialize, params}, 5000) do
      {:ok, result} ->
        normalized = normalize_initialize_result(result, params, server_info)
        put_success(conn, deep_stringify_keys(normalized), id)

      {:ok, result, _state} ->
        normalized = normalize_initialize_result(result, params, server_info)
        put_success(conn, deep_stringify_keys(normalized), id)

      {:error, reason} ->
        put_error(conn, "Initialize failed", reason, id)
    end
  rescue
    error -> put_error(conn, "Initialize failed", error, id)
  end

  # Builds a schema-valid InitializeResult from whatever the handler returned.
  #
  # Two historical bugs are fixed here:
  #
  #   * Protocol version override — the previous `Map.put_new("protocolVersion",
  #     ...)` + `Map.put_new(:protocolVersion, ...)` pair always injected the
  #     hardcoded default. The handler sets the ATOM key, but the STRING-key
  #     `put_new` still fired (different key), and after `deep_stringify_keys`
  #     the two collided with the default winning. We now negotiate the version
  #     explicitly (echo the client's requested version when supported) and only
  #     fall back to a handler-provided / default version, never override one.
  #
  #   * Empty serverInfo — an InitializeResult without `serverInfo.name` is
  #     invalid and makes strict clients (codex/rmcp) reject the handshake. We
  #     guarantee a non-empty serverInfo.
  defp normalize_initialize_result(result, params, server_info) do
    {result, handler_version} = pop_any(result, "protocolVersion", :protocolVersion)
    version = negotiate_protocol_version(params, handler_version)

    result = Map.put(result, "protocolVersion", version)

    handler_server_info = Map.get(result, "serverInfo") || Map.get(result, :serverInfo)
    name = Map.get(result, "name") || Map.get(result, :name)
    version_field = Map.get(result, "version") || Map.get(result, :version)

    server_info_value =
      cond do
        non_empty_map?(handler_server_info) -> handler_server_info
        name && version_field -> %{"name" => name, "version" => version_field}
        true -> ensure_server_info(server_info)
      end

    result
    |> Map.delete(:serverInfo)
    |> Map.put("serverInfo", server_info_value)
  end

  # Echo the client's requested protocolVersion when ex_mcp supports it,
  # otherwise prefer the handler's negotiated version (if supported), else the
  # server's latest supported version. Never returns an unsupported version.
  defp negotiate_protocol_version(params, handler_version \\ nil) do
    requested = is_map(params) && Map.get(params, "protocolVersion")
    supported = VersionRegistry.supported_versions()

    cond do
      is_binary(requested) and requested in supported -> requested
      is_binary(handler_version) and handler_version in supported -> handler_version
      true -> @default_protocol_version
    end
  end

  # Guarantees a non-empty serverInfo map (with at least a name). Prefers the
  # primary value, falls back to the configured one, then a sane default.
  defp ensure_server_info(primary, fallback \\ %{}) do
    cond do
      non_empty_map?(primary) -> deep_stringify_keys(primary)
      non_empty_map?(fallback) -> deep_stringify_keys(fallback)
      true -> @fallback_server_info
    end
  end

  defp non_empty_map?(map) when is_map(map), do: map_size(map) > 0
  defp non_empty_map?(_), do: false

  # Removes both the string and atom variants of a key and returns the first
  # value found, so a handler-provided value survives `deep_stringify_keys`
  # without colliding with an injected default of the other key flavour.
  defp pop_any(map, string_key, atom_key) do
    value = Map.get(map, string_key) || Map.get(map, atom_key)
    {map |> Map.delete(string_key) |> Map.delete(atom_key), value}
  end

  # --- tools/list ---

  def handle_tools_list(conn, handler, :direct, _params, id) do
    tools = handler.get_tools() |> Map.values() |> deep_stringify_keys()
    put_success(conn, %{"tools" => tools}, id)
  end

  def handle_tools_list(conn, server_pid, :genserver, _params, id) do
    tools = GenServer.call(server_pid, :get_tools, 5000) |> Map.values() |> deep_stringify_keys()
    put_success(conn, %{"tools" => tools}, id)
  rescue
    error -> put_error(conn, "Tools list failed", error, id)
  end

  def handle_tools_list(conn, server_pid, :handler, params, id) do
    cursor = Map.get(params, "cursor")

    case GenServer.call(server_pid, {:list_tools, cursor}, 5000) do
      {:ok, tools, next_cursor, _state} ->
        result = %{"tools" => deep_stringify_keys(tools)}
        result = if next_cursor, do: Map.put(result, "nextCursor", next_cursor), else: result
        put_success(conn, result, id)

      {:error, reason} ->
        put_error(conn, "Tools list failed", reason, id)
    end
  rescue
    error -> put_error(conn, "Tools list failed", error, id)
  end

  # --- tools/call ---

  def handle_tools_call(conn, handler, :direct, params, id) do
    tool_name = Map.get(params, "name")
    arguments = Map.get(params, "arguments", %{})

    :telemetry.execute(
      [:ex_mcp, :server, :tool, :called],
      %{},
      %{tool_name: tool_name, mode: :direct}
    )

    case handler.handle_tool_call(tool_name, arguments, %{}) do
      {:ok, result} ->
        put_success(conn, wrap_tool_result(result), id)

      {:error, reason} ->
        put_success(conn, tool_error_result(reason), id)
    end
  end

  def handle_tools_call(conn, server_pid, :genserver, params, id) do
    tool_name = Map.get(params, "name")
    arguments = Map.get(params, "arguments", %{})

    :telemetry.execute(
      [:ex_mcp, :server, :tool, :called],
      %{},
      %{tool_name: tool_name, mode: :genserver}
    )

    case GenServer.call(server_pid, {:execute_tool, tool_name, arguments}, 10000) do
      {:ok, result} ->
        put_success(conn, wrap_tool_result(result), id)

      {:error, reason} ->
        put_success(conn, tool_error_result(reason), id)
    end
  rescue
    error -> put_error(conn, "Tool call failed", error, id)
  end

  def handle_tools_call(conn, server_pid, :handler, params, id) do
    tool_name = Map.get(params, "name")
    arguments = Map.get(params, "arguments", %{})

    :telemetry.execute(
      [:ex_mcp, :server, :tool, :called],
      %{},
      %{tool_name: tool_name, mode: :handler}
    )

    case GenServer.call(server_pid, {:call_tool, tool_name, arguments}, 10000) do
      {:ok, result} ->
        put_success(conn, wrap_tool_result(result), id)

      {:error, reason} ->
        put_success(conn, tool_error_result(reason), id)
    end
  rescue
    error -> put_error(conn, "Tool call failed", error, id)
  end

  # --- resources/list ---

  def handle_resources_list(conn, handler, :direct, _params, id) do
    resources = handler.get_resources() |> Map.values() |> deep_stringify_keys()
    put_success(conn, %{"resources" => resources}, id)
  end

  def handle_resources_list(conn, server_pid, :genserver, _params, id) do
    resources =
      GenServer.call(server_pid, :get_resources, 5000) |> Map.values() |> deep_stringify_keys()

    put_success(conn, %{"resources" => resources}, id)
  rescue
    error -> put_error(conn, "Resources list failed", error, id)
  end

  def handle_resources_list(conn, server_pid, :handler, params, id) do
    cursor = Map.get(params, "cursor")

    case GenServer.call(server_pid, {:list_resources, cursor}, 5000) do
      {:ok, resources, next_cursor, _state} ->
        result = %{"resources" => deep_stringify_keys(resources)}
        result = if next_cursor, do: Map.put(result, "nextCursor", next_cursor), else: result
        put_success(conn, result, id)

      {:error, reason} ->
        put_error(conn, "Resources list failed", reason, id)
    end
  rescue
    error -> put_error(conn, "Resources list failed", error, id)
  end

  # --- resources/templates/list ---
  #
  # Codex's MCP connection manager probes `resources/templates/list` on every
  # server right after `initialize` (alongside `resources/list`). Before this
  # route existed, the method fell through to `handle_custom_method`, which
  # answered with a malformed JSON-RPC error (`-32603 "Unknown message"` from the
  # handler GenServer's catch-all). codex logs that as a failure and treats the
  # freshly-connected server as unhealthy during the exact window it uses to
  # decide tool readiness, so the doc.* tools intermittently never reach the
  # turn. The MCP spec lets a server that exposes no resource templates answer
  # the probe with an empty list, so do exactly that — uniformly across modes —
  # so the server presents as healthy the instant `initialize` completes.

  def handle_resources_templates_list(conn, _handler, _mode, _params, id) do
    put_success(conn, %{"resourceTemplates" => []}, id)
  end

  # --- resources/read ---

  def handle_resources_read(conn, handler, :direct, params, id) do
    uri = Map.get(params, "uri")

    :telemetry.execute(
      [:ex_mcp, :server, :resource, :read],
      %{},
      %{uri: uri, mode: :direct}
    )

    case handler.handle_resource_read(uri, uri, %{}) do
      {:ok, contents, _state} ->
        put_success(conn, %{"contents" => deep_stringify_keys(List.wrap(contents))}, id)

      {:error, reason} ->
        put_error(conn, "Resource read failed", reason, id)
    end
  end

  def handle_resources_read(conn, server_pid, :genserver, params, id) do
    uri = Map.get(params, "uri")

    :telemetry.execute(
      [:ex_mcp, :server, :resource, :read],
      %{},
      %{uri: uri, mode: :genserver}
    )

    case GenServer.call(server_pid, {:read_resource, uri}, 5000) do
      {:ok, contents} ->
        put_success(conn, %{"contents" => deep_stringify_keys(List.wrap(contents))}, id)

      {:error, reason} ->
        put_error(conn, "Resource read failed", reason, id)
    end
  rescue
    error -> put_error(conn, "Resource read failed", error, id)
  end

  def handle_resources_read(conn, server_pid, :handler, params, id) do
    uri = Map.get(params, "uri")

    :telemetry.execute(
      [:ex_mcp, :server, :resource, :read],
      %{},
      %{uri: uri, mode: :handler}
    )

    case GenServer.call(server_pid, {:read_resource, uri}, 5000) do
      {:ok, contents, _state} ->
        put_success(conn, %{"contents" => deep_stringify_keys(List.wrap(contents))}, id)

      {:ok, contents} ->
        put_success(conn, %{"contents" => deep_stringify_keys(List.wrap(contents))}, id)

      {:error, reason} ->
        put_error(conn, "Resource read failed", reason, id)
    end
  rescue
    error -> put_error(conn, "Resource read failed", error, id)
  end

  # --- resources/subscribe ---

  def handle_resources_subscribe(conn, _handler, :direct, params, id) do
    _uri = Map.get(params, "uri")
    put_success(conn, %{}, id)
  end

  def handle_resources_subscribe(conn, server_pid, :genserver, params, id) do
    uri = Map.get(params, "uri")

    case GenServer.call(server_pid, {:subscribe_resource, uri}, 5000) do
      :ok -> put_success(conn, %{}, id)
      {:error, reason} -> put_error(conn, "Subscribe failed", reason, id)
    end
  rescue
    error -> put_error(conn, "Subscribe failed", error, id)
  end

  def handle_resources_subscribe(conn, server_pid, :handler, params, id) do
    uri = Map.get(params, "uri")

    case GenServer.call(server_pid, {:subscribe_resource, uri}, 5000) do
      :ok -> put_success(conn, %{}, id)
      {:ok, _state} -> put_success(conn, %{}, id)
      {:error, reason} -> put_error(conn, "Subscribe failed", reason, id)
    end
  rescue
    error -> put_error(conn, "Subscribe failed", error, id)
  end

  # --- resources/unsubscribe ---

  def handle_resources_unsubscribe(conn, _handler, :direct, params, id) do
    _uri = Map.get(params, "uri")
    put_success(conn, %{}, id)
  end

  def handle_resources_unsubscribe(conn, server_pid, :genserver, params, id) do
    uri = Map.get(params, "uri")

    case GenServer.call(server_pid, {:unsubscribe_resource, uri}, 5000) do
      :ok -> put_success(conn, %{}, id)
      {:error, reason} -> put_error(conn, "Unsubscribe failed", reason, id)
    end
  rescue
    error -> put_error(conn, "Unsubscribe failed", error, id)
  end

  def handle_resources_unsubscribe(conn, server_pid, :handler, params, id) do
    uri = Map.get(params, "uri")

    case GenServer.call(server_pid, {:unsubscribe_resource, uri}, 5000) do
      :ok -> put_success(conn, %{}, id)
      {:ok, _state} -> put_success(conn, %{}, id)
      {:error, reason} -> put_error(conn, "Unsubscribe failed", reason, id)
    end
  rescue
    error -> put_error(conn, "Unsubscribe failed", error, id)
  end

  # --- prompts/list ---

  def handle_prompts_list(conn, handler, :direct, _params, id) do
    prompts = handler.get_prompts() |> Map.values() |> deep_stringify_keys()
    put_success(conn, %{"prompts" => prompts}, id)
  end

  def handle_prompts_list(conn, server_pid, :genserver, _params, id) do
    prompts =
      GenServer.call(server_pid, :get_prompts, 5000) |> Map.values() |> deep_stringify_keys()

    put_success(conn, %{"prompts" => prompts}, id)
  rescue
    error -> put_error(conn, "Prompts list failed", error, id)
  end

  def handle_prompts_list(conn, server_pid, :handler, params, id) do
    cursor = Map.get(params, "cursor")

    case GenServer.call(server_pid, {:list_prompts, cursor}, 5000) do
      {:ok, prompts, next_cursor, _state} ->
        result = %{"prompts" => deep_stringify_keys(prompts)}
        result = if next_cursor, do: Map.put(result, "nextCursor", next_cursor), else: result
        put_success(conn, result, id)

      {:error, reason} ->
        put_error(conn, "Prompts list failed", reason, id)
    end
  rescue
    error -> put_error(conn, "Prompts list failed", error, id)
  end

  # --- prompts/get ---

  def handle_prompts_get(conn, handler, :direct, params, id) do
    name = Map.get(params, "name")
    arguments = Map.get(params, "arguments", %{})

    :telemetry.execute(
      [:ex_mcp, :server, :prompt, :rendered],
      %{},
      %{name: name, mode: :direct}
    )

    case handler.handle_get_prompt(name, arguments, %{}) do
      {:ok, result, _state} ->
        put_success(conn, deep_stringify_keys(result), id)

      {:error, reason} ->
        put_error(conn, "Prompt get failed", reason, id)
    end
  end

  def handle_prompts_get(conn, server_pid, :genserver, params, id) do
    name = Map.get(params, "name")
    arguments = Map.get(params, "arguments", %{})

    :telemetry.execute(
      [:ex_mcp, :server, :prompt, :rendered],
      %{},
      %{name: name, mode: :genserver}
    )

    case GenServer.call(server_pid, {:get_prompt, name, arguments}, 5000) do
      {:ok, result} ->
        put_success(conn, deep_stringify_keys(result), id)

      {:error, reason} ->
        put_error(conn, "Prompt get failed", reason, id)
    end
  rescue
    error -> put_error(conn, "Prompt get failed", error, id)
  end

  def handle_prompts_get(conn, server_pid, :handler, params, id) do
    name = Map.get(params, "name")
    arguments = Map.get(params, "arguments", %{})

    :telemetry.execute(
      [:ex_mcp, :server, :prompt, :rendered],
      %{},
      %{name: name, mode: :handler}
    )

    case GenServer.call(server_pid, {:get_prompt, name, arguments}, 5000) do
      {:ok, result, _state} ->
        put_success(conn, deep_stringify_keys(result), id)

      {:ok, result} ->
        put_success(conn, deep_stringify_keys(result), id)

      {:error, reason} ->
        put_error(conn, "Prompt get failed", reason, id)
    end
  rescue
    error -> put_error(conn, "Prompt get failed", error, id)
  end

  # --- completion/complete ---

  def handle_completion_complete(conn, _handler, :direct, _params, id) do
    put_success(conn, %{"completion" => %{"values" => [], "hasMore" => false, "total" => 0}}, id)
  end

  def handle_completion_complete(conn, server_pid, :genserver, params, id) do
    case GenServer.call(server_pid, {:complete, params["ref"], params["argument"]}, 5000) do
      {:ok, result} -> put_success(conn, deep_stringify_keys(result), id)
      {:ok, result, _state} -> put_success(conn, deep_stringify_keys(result), id)
      {:error, reason} -> put_error(conn, "Completion failed", reason, id)
    end
  rescue
    error -> put_error(conn, "Completion failed", error, id)
  end

  def handle_completion_complete(conn, server_pid, :handler, params, id) do
    case GenServer.call(server_pid, {:complete, params["ref"], params["argument"]}, 5000) do
      {:ok, result, _state} -> put_success(conn, deep_stringify_keys(result), id)
      {:ok, result} -> put_success(conn, deep_stringify_keys(result), id)
      {:error, reason} -> put_error(conn, "Completion failed", reason, id)
    end
  rescue
    error -> put_error(conn, "Completion failed", error, id)
  end

  # --- custom method ---

  def handle_custom_method(conn, handler, :direct, method, params, id) do
    if function_exported?(handler, :handle_custom_request, 3) do
      case handler.handle_custom_request(method, params, %{}) do
        {:ok, result, _state} -> put_success(conn, deep_stringify_keys(result), id)
        {:error, reason} -> put_error(conn, "Custom method failed", reason, id)
      end
    else
      put_method_not_found(conn, id)
    end
  end

  def handle_custom_method(conn, server_pid, :genserver, method, params, id) do
    case GenServer.call(server_pid, {:custom_method, method, params}, 5000) do
      {:ok, result} ->
        put_success(conn, deep_stringify_keys(result), id)

      {:error, reason} when reason in [:method_not_found, :unknown_request] ->
        put_method_not_found(conn, id)

      {:error, reason} ->
        put_error(conn, "Custom method failed", reason, id)

      _ ->
        put_method_not_found(conn, id)
    end
  catch
    :exit, _ -> put_method_not_found(conn, id)
  end

  def handle_custom_method(conn, server_pid, :handler, method, params, id) do
    case GenServer.call(server_pid, {:custom_request, method, params}, 5000) do
      {:ok, result, _state} -> put_success(conn, deep_stringify_keys(result), id)
      {:ok, result} -> put_success(conn, deep_stringify_keys(result), id)
      {:error, :method_not_found} -> put_method_not_found(conn, id)
      {:error, reason} -> put_error(conn, "Custom method failed", reason, id)
    end
  rescue
    _ -> put_method_not_found(conn, id)
  end

  # --- Response helpers ---

  defp put_success(conn, result, id) do
    response = %{"jsonrpc" => "2.0", "result" => result, "id" => id}
    %{conn | response: response}
  end

  defp put_error(conn, message, reason, id) do
    response = %{
      "jsonrpc" => "2.0",
      "error" => %{
        "code" => -32603,
        "message" => message,
        "data" => %{"reason" => inspect(reason)}
      },
      "id" => id
    }

    %{conn | response: response}
  end

  defp put_method_not_found(conn, id) do
    response = %{
      "jsonrpc" => "2.0",
      "error" => %{
        "code" => -32601,
        "message" => "Method not found"
      },
      "id" => id
    }

    %{conn | response: response}
  end

  defp wrap_tool_result(result) when is_list(result) do
    %{"content" => deep_stringify_keys(result)}
  end

  defp wrap_tool_result(%{content: content} = result) do
    result
    |> Map.delete(:content)
    |> Map.put("content", deep_stringify_keys(List.wrap(content)))
    |> deep_stringify_keys()
  end

  defp wrap_tool_result(%{"content" => _} = result), do: deep_stringify_keys(result)

  defp wrap_tool_result(result) when is_map(result) do
    deep_stringify_keys(result)
  end

  defp tool_error_result(reason) do
    %{
      "content" => [%{"type" => "text", "text" => to_string(reason)}],
      "isError" => true
    }
  end

  # Recursively convert atom keys to strings
  defp deep_stringify_keys(list) when is_list(list) do
    Enum.map(list, &deep_stringify_keys/1)
  end

  defp deep_stringify_keys(map) when is_map(map) and not is_struct(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), deep_stringify_keys(value)}
      {key, value} -> {key, deep_stringify_keys(value)}
    end)
  end

  defp deep_stringify_keys(value), do: value
end
