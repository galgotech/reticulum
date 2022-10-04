defmodule RetWeb.HubChannelTest do
  use RetWeb.ChannelCase
  import Ret.TestHelpers

  alias RetWeb.{Presence, SessionSocket}
  alias Ret.{AppConfig, Account, Repo, Hub}

  @default_join_params %{"profile" => %{}, "context" => %{}}

  setup [:create_account, :create_owned_file, :create_scene, :create_hub, :create_account]

  setup do
    {:ok, socket} = connect(SessionSocket, %{})
    {:ok, socket: socket}
  end

  describe "authorization" do
    test "joining hub works", %{socket: socket, hub: hub} do
      {:ok, %{session_id: _session_id}, _socket} =
        subscribe_and_join(socket, "hub:#{hub.hub_sid}", @default_join_params)
    end

    test "joining hub does not work if account is disabled", %{socket: socket, hub: hub} do
      disabled_account = create_account("disabled_account")
      disabled_account |> Ecto.Changeset.change(state: :disabled) |> Ret.Repo.update!()

      {:error, %{reason: "join_denied"}} =
        subscribe_and_join(socket, "hub:#{hub.hub_sid}", join_params_for_account(disabled_account))
    end
  end

  describe "presence" do
    test "joining hub registers in presence", %{socket: socket, hub: hub} do
      {:ok, %{session_id: session_id}, socket} = subscribe_and_join(socket, "hub:#{hub.hub_sid}", @default_join_params)
      :timer.sleep(100)
      presence = socket |> Presence.list()
      assert presence[session_id]
    end
  end

  defp join_params_for_account(account) do
    {:ok, token, _params} = account |> Ret.Guardian.encode_and_sign()
    join_params(%{"auth_token" => token})
  end

  defp join_params(%{} = params) do
    Map.merge(@default_join_params, params)
  end

  defp join_hub(socket, %Hub{} = hub, params) do
    subscribe_and_join(socket, "hub:#{hub.hub_sid}", params)
  end
end
