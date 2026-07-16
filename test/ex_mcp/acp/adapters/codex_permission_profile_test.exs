defmodule ExMCP.ACP.Adapters.CodexPermissionProfileTest do
  use ExUnit.Case, async: true

  alias ExMCP.ACP.Adapters.Codex

  test "keeps a process permission profile active by omitting legacy sandbox" do
    {:ok, state} = Codex.init(use_permission_profile: true)

    assert {:ok, request, _state} =
             Codex.translate_outbound(
               %{
                 "method" => "session/new",
                 "id" => 1,
                 "params" => %{"cwd" => "/workspace", "sandbox" => "workspace-write"}
               },
               state
             )

    assert %{"method" => "thread/start", "params" => params} =
             request |> IO.iodata_to_binary() |> Jason.decode!()

    refute Map.has_key?(params, "sandbox")
  end

  test "forwards legacy sandbox when no process permission profile is requested" do
    {:ok, state} = Codex.init([])

    assert {:ok, request, _state} =
             Codex.translate_outbound(
               %{
                 "method" => "session/new",
                 "id" => 1,
                 "params" => %{"cwd" => "/workspace", "sandbox" => "workspace-write"}
               },
               state
             )

    assert %{"params" => %{"sandbox" => "workspace-write"}} =
             request |> IO.iodata_to_binary() |> Jason.decode!()
  end

  test "fails session creation when Codex does not activate the requested profile" do
    {:ok, state} = Codex.init(expected_permission_profile: "ecrits_workspace")

    state = %{
      state
      | pending_requests: %{1 => %{type: :thread_start, acp_id: "acp-session"}}
    }

    assert {:messages, [response], _state} =
             Codex.translate_inbound(
               Jason.encode!(%{
                 "id" => 1,
                 "result" => %{
                   "thread" => %{"id" => "thread-1"},
                   "activePermissionProfile" => nil
                 }
               }),
               state
             )

    assert %{"error" => %{"code" => -32_002, "message" => message}} = response
    assert message =~ "ecrits_workspace"
  end

  test "accepts session creation only after the requested profile is active" do
    {:ok, state} = Codex.init(expected_permission_profile: "ecrits_workspace")

    state = %{
      state
      | pending_requests: %{1 => %{type: :thread_start, acp_id: "acp-session"}}
    }

    assert {:messages, [%{"result" => %{"sessionId" => "thread-1"}}], _state} =
             Codex.translate_inbound(
               Jason.encode!(%{
                 "id" => 1,
                 "result" => %{
                   "thread" => %{"id" => "thread-1"},
                   "activePermissionProfile" => %{"id" => "ecrits_workspace"}
                 }
               }),
               state
             )
  end
end
