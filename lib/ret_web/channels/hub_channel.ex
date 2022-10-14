defmodule RetWeb.HubChannel do
  @moduledoc "Ret Web Channel for Hubs"

  use RetWeb, :channel

  import Canada, only: [can?: 2]

  alias Ret.{
    AppConfig,
    Hub,
    Account,
    AccountExternal,
    Repo,
    RoomObject,
    OwnedFile,
    Scene,
    Storage,
    SessionStat,
    Statix,
    WebPushSubscription
  }

  alias RetWeb.{Presence}
  alias RetWeb.Api.V1.{HubView}

  intercept([
    "hub_refresh",
    "mute",
    "message",
    "block",
    "unblock",
    # See internal_naf_event_for/2
    "maybe-naf",
    "maybe-nafr"
  ])

  def join("hub:" <> hub_sid, %{"profile" => profile, "context" => context} = params, socket) do
    hub =
      Hub
      |> Repo.get_by(hub_sid: hub_sid)
      |> Repo.preload(Hub.hub_preloads())

    socket
    |> assign(:profile, profile)
    |> assign(:context, context)
    |> assign(:block_naf, false)
    |> assign(:blocked_session_ids, %{})
    |> assign(:blocked_by_session_ids, %{})
    |> assign(:has_blocks, false)
    |> assign(:has_embeds, false)
    |> perform_join(
      hub,
      context,
      params |> Map.take(["push_subscription_endpoint", "auth_token"])
    )
  end

  defp perform_join(_socket, nil, _context, _params) do
    Statix.increment("ret.channels.hub.joins.not_found")
    {:error, %{message: "No such Hub", reason: "not_found"}}
  end

  defp perform_join(socket, hub, context, params) do
    account =
      case Ret.Guardian.resource_from_token(params["auth_token"]) do
        {:ok, %Account{} = account, _claims} -> account
        _ -> nil
      end

    account_external = account |> Account.external(params["auth_token"])
    account_can_update = account_external |> can?(update_hub(hub))
    has_perms_token = account_external.perms
    perms_token_can_join = account_external |> can?(join_hub(hub))

    params =
      params
      |> Map.merge(%{
        account_can_update: account_can_update,
        has_perms_token: has_perms_token,
        perms_token_can_join: perms_token_can_join,
      })

    hub |> join_with_hub(account, socket, context, params)
  end

  # Optimization: "raw" NAF event, with the underlying NAF payload as a string.
  # By going through this event, the server can avoid parsing the NAF messages.
  def handle_in("nafr" = event, %{"naf" => naf_payload} = payload, socket) do
    # We expect the client to have stripped the "isFirstSync" keys from the message
    # for this optimization.
    if !String.contains?(naf_payload, "isFirstSync") do
      broadcast_from!(socket, event |> internal_naf_event_for(socket), payload |> payload_with_from(socket))
      {:noreply, socket}
    else
      # Full syncs must be properly authorized
      handle_in("naf", naf_payload |> Jason.decode!(), socket)
    end
  end

  # Captures all inbound NAF messages that result in spawned objects.
  def handle_in(
        "naf" = event,
        %{"data" => %{"isFirstSync" => true, "persistent" => false, "template" => template}} = payload,
        socket
      ) do
    data = payload["data"]

    if template |> spawn_permitted?(socket) do
      data =
        data
        |> Map.put("creator", socket.assigns.session_id)
        |> Map.put("owner", socket.assigns.session_id)

      payload = payload |> Map.put("data", data)

      broadcast_from!(socket, event |> internal_naf_event_for(socket), payload |> payload_with_from(socket))

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  # Captures all inbound NAF Update Multi messages
  def handle_in("naf" = event, %{"dataType" => "um", "data" => %{"d" => updates}} = payload, socket) do
    if updates |> Enum.any?(& &1["isFirstSync"]) do
      # Do not broadcast "um" messages that contain isFirstSyncs. NAF should never send these, so we'd only see them
      # from a malicious client.
      {:noreply, socket}
    else
      broadcast_from!(socket, event |> internal_naf_event_for(socket), payload |> payload_with_from(socket))

      {:noreply, socket}
    end
  end

  # Fallthrough for all other NAF dataTypes
  def handle_in("naf" = event, payload, socket) do
    broadcast_from!(socket, event |> internal_naf_event_for(socket), payload |> payload_with_from(socket))
    {:noreply, socket}
  end

  def handle_in("events:entering", _payload, socket) do
    context = socket.assigns.context || %{}
    socket = socket |> assign(:context, context |> Map.put("entering", true)) |> broadcast_presence_update

    {:noreply, socket}
  end

  def handle_in("events:entering_cancelled", _payload, socket) do
    context = socket.assigns.context || %{}
    socket = socket |> assign(:context, context |> Map.delete("entering")) |> broadcast_presence_update

    {:noreply, socket}
  end

  def handle_in("events:entered", %{"initialOccupantCount" => occupant_count} = payload, socket) do
    socket =
      socket
      |> handle_max_occupant_update(occupant_count)
      |> handle_entered_event(payload)

    Statix.increment("ret.channels.hub.event_entered", 1)

    {:noreply, socket}
  end

  def handle_in("events:entered", payload, socket) do
    socket = socket |> handle_entered_event(payload)

    Statix.increment("ret.channels.hub.event_entered", 1)

    {:noreply, socket}
  end

  def handle_in("events:object_spawned", %{"object_type" => object_type}, socket) do
    socket = socket |> handle_object_spawned(object_type)

    Statix.increment("ret.channels.hub.objects_spawned", 1)

    {:noreply, socket}
  end

  def handle_in("events:profile_updated", %{"profile" => profile}, socket) do
    socket = socket |> assign(:profile, profile) |> broadcast_presence_update
    {:noreply, socket}
  end

  def handle_in("events:begin_recording", _payload, socket), do: socket |> set_presence_flag(:recording, true)
  def handle_in("events:end_recording", _payload, socket), do: socket |> set_presence_flag(:recording, false)
  def handle_in("events:raise_hand", _payload, socket), do: socket |> set_presence_flag(:hand_raised, true)
  def handle_in("events:lower_hand", _payload, socket), do: socket |> set_presence_flag(:hand_raised, false)
  def handle_in("events:begin_streaming", _payload, socket), do: socket |> set_presence_flag(:streaming, true)
  def handle_in("events:end_streaming", _payload, socket), do: socket |> set_presence_flag(:streaming, false)
  def handle_in("events:begin_typing", _payload, socket), do: socket |> set_presence_flag(:typing, true)
  def handle_in("events:end_typing", _payload, socket), do: socket |> set_presence_flag(:typing, false)

  def handle_in("message" = event, %{"type" => type} = payload, socket) do
    account = Guardian.Phoenix.Socket.current_resource(socket)
    hub = socket |> hub_for_socket

    if (type != "photo" and type != "video") or account |> can?(spawn_camera(hub)) do
      broadcast!(
        socket,
        event,
        payload |> Map.put(:session_id, socket.assigns.session_id) |> payload_with_from(socket)
      )
    end

    {:noreply, socket}
  end

  def handle_in("mute" = event, payload, socket) do
    hub = socket |> hub_for_socket
    account = Guardian.Phoenix.Socket.current_resource(socket)

    if account |> can?(mute_users(hub)) do
      broadcast_from!(socket, event, payload)
    end

    {:noreply, socket}
  end

  def handle_in("subscribe", %{"subscription" => subscription}, socket) do
    socket
    |> hub_for_socket
    |> WebPushSubscription.subscribe_to_hub(subscription)

    {:noreply, socket}
  end

  def handle_in("unsubscribe", %{"subscription" => subscription}, socket) do
    socket
    |> hub_for_socket
    |> WebPushSubscription.unsubscribe_from_hub(subscription)

    has_remaining_subscriptions = WebPushSubscription.endpoint_has_subscriptions?(subscription["endpoint"])

    {:reply, {:ok, %{has_remaining_subscriptions: has_remaining_subscriptions}}, socket}
  end

  def handle_in("sign_out", _payload, socket) do
    socket = Guardian.Phoenix.Socket.put_current_resource(socket, nil)
    socket = Guardian.Phoenix.Socket.put_current_token(socket, nil)
    broadcast_presence_update(socket)

    # Disconnect
    Process.send_after(self(), :close_channel, 5000)

    {:reply, {:ok, %{}}, socket}
  end

  def handle_in(
        "pin",
        %{
          "id" => object_id,
          "gltf_node" => gltf_node,
          "file_id" => file_id,
          "file_access_token" => file_access_token,
          "promotion_token" => promotion_token
        },
        socket
      ) do
    with_account(socket, fn account ->
      hub = socket |> hub_for_socket

      if account |> can?(pin_objects(hub)) do
        perform_pin!(object_id, gltf_node, account, socket)
        Storage.promote(file_id, file_access_token, promotion_token, account)
        OwnedFile.set_active(file_id, account.account_id)
      end
    end)
  end

  def handle_in("pin", %{"id" => object_id, "gltf_node" => gltf_node}, socket) do
    with_account(socket, fn account ->
      hub = socket |> hub_for_socket

      if account |> can?(pin_objects(hub)) do
        perform_pin!(object_id, gltf_node, account, socket)
      end
    end)
  end

  def handle_in("unpin", %{"id" => object_id, "file_id" => file_id}, socket) do
    hub = socket |> hub_for_socket

    case Guardian.Phoenix.Socket.current_resource(socket) do
      %Account{} = account ->
        if account |> can?(pin_objects(hub)) do
          RoomObject.perform_unpin(hub, object_id)
          OwnedFile.set_inactive(file_id, account.account_id)
        end

      _ ->
        nil
    end

    {:noreply, socket}
  end

  def handle_in("unpin", %{"id" => object_id}, socket) do
    hub = socket |> hub_for_socket

    case Guardian.Phoenix.Socket.current_resource(socket) do
      %Account{} = account ->
        if account |> can?(pin_objects(hub)) do
          RoomObject.perform_unpin(hub, object_id)
        end

      _ ->
        nil
    end

    {:noreply, socket}
  end

  def handle_in("get_host", _args, socket) do
    hub = socket |> hub_for_socket |> Hub.ensure_host()
    {:reply, {:ok, %{host: hub.host, port: Hub.janus_port(), turn: Hub.generate_turn_info()}}, socket}
  end

  def handle_in("update_hub", payload, socket) do
    hub = socket |> hub_for_socket
    account = Guardian.Phoenix.Socket.current_resource(socket)

    if account |> can?(update_hub(hub)) do
      name_changed = hub.name != payload["name"]
      description_changed = hub.description != payload["description"]
      member_permissions_changed = hub.member_permissions != payload |> Hub.member_permissions_from_attrs()
      room_size_changed = hub.room_size != payload["room_size"]
      # Older clients may not send an entry_mode in the payload.
      entry_mode_changed = payload["entry_mode"] !== nil and hub.entry_mode != payload["entry_mode"]

      stale_fields = []
      stale_fields = if name_changed, do: ["name" | stale_fields], else: stale_fields
      stale_fields = if description_changed, do: ["description" | stale_fields], else: stale_fields
      stale_fields = if member_permissions_changed, do: ["member_permissions" | stale_fields], else: stale_fields
      stale_fields = if room_size_changed, do: ["room_size" | stale_fields], else: stale_fields
      stale_fields = if entry_mode_changed, do: ["entry_mode" | stale_fields], else: stale_fields

      hub
      |> Hub.add_attrs_to_changeset(payload)
      |> Hub.add_member_permissions_to_changeset(payload)
      |> Hub.maybe_add_entry_mode_to_changeset(payload)
      |> Repo.update!()
      |> Repo.preload(Hub.hub_preloads())
      |> broadcast_hub_refresh!(socket, stale_fields)
    end

    {:noreply, socket}
  end

  def handle_in("close_hub", _payload, socket) do
    socket |> handle_entry_mode_change(:deny)
  end

  def handle_in("update_scene", %{"url" => url}, socket) do
    hub = socket |> hub_for_socket |> Repo.preload([:scene, :scene_listing])
    account = Guardian.Phoenix.Socket.current_resource(socket)

    if account |> can?(update_hub(hub)) do
      endpoint_host = RetWeb.Endpoint.host()

      case url |> URI.parse() do
        %URI{host: ^endpoint_host, path: "/scenes/" <> scene_path} ->
          scene_or_listing = scene_path |> String.split("/") |> Enum.at(0) |> Scene.scene_or_scene_listing_by_sid()
          hub |> Hub.changeset_for_new_scene(scene_or_listing)

        _ ->
          hub |> Hub.changeset_for_new_environment_url(url)
      end
      |> Repo.update!()
      |> Repo.preload(Hub.hub_preloads(), force: true)
      |> broadcast_hub_refresh!(socket, ["scene"])
    end

    {:noreply, socket}
  end

  def handle_in("block" = event, %{"session_id" => session_id} = payload, socket) do
    socket =
      socket
      |> assign(:blocked_session_ids, socket.assigns.blocked_session_ids |> Map.put(session_id, true))
      |> assign_has_blocks

    broadcast_from!(socket, event, payload |> payload_with_from(socket))
    {:noreply, socket}
  end

  def handle_in("unblock" = event, %{"session_id" => session_id} = payload, socket) do
    socket =
      socket
      |> assign(:blocked_session_ids, socket.assigns.blocked_session_ids |> Map.delete(session_id))
      |> assign_has_blocks

    broadcast_from!(socket, event, payload |> payload_with_from(socket))
    {:noreply, socket}
  end

  def handle_in("kick", %{"session_id" => session_id}, socket) do
    account = Guardian.Phoenix.Socket.current_resource(socket)
    hub = socket |> hub_for_socket

    if account |> can?(kick_users(hub)) do
      RetWeb.Endpoint.broadcast("session:#{session_id}", "disconnect", %{})
    end

    {:noreply, socket}
  end

  # NOTE: block_naf will only work if the hub is embedded. We *only* enable packet filtering
  # (and therefore, only respect block_naf) when a hub is embedded (or if there are blocks on the socket.)
  def handle_in("block_naf", _payload, socket), do: {:noreply, socket |> assign(:block_naf, true)}
  def handle_in("unblock_naf", _payload, socket), do: {:noreply, socket |> assign(:block_naf, false)}

  def handle_in(_message, _payload, socket) do
    {:noreply, socket}
  end

  # If the maybe- variant of the naf/nafr messages are seen, we are performing packet filtering due to blocks
  # or iframe embeds opting out of NAF traffic. Handle them appropriately. (This is expensive, and should be rare!)
  def handle_out(event, payload, socket) when event in ["maybe-nafr"] do
    %{block_naf: block_naf, blocked_session_ids: blocked_session_ids, blocked_by_session_ids: blocked_by_session_ids} =
      socket.assigns

    socket |> maybe_push_naf("nafr", payload, block_naf, blocked_session_ids, blocked_by_session_ids)
  end

  def handle_out(event, payload, socket) when event in ["maybe-naf"] do
    %{block_naf: block_naf, blocked_session_ids: blocked_session_ids, blocked_by_session_ids: blocked_by_session_ids} =
      socket.assigns

    socket |> maybe_push_naf("naf", payload, block_naf, blocked_session_ids, blocked_by_session_ids)
  end

  def handle_out("mute" = event, %{"session_id" => session_id} = payload, socket) do
    if socket.assigns.session_id == session_id do
      push(socket, event, payload)
    end

    {:noreply, socket}
  end

  def handle_out("hub_refresh" = event, %{stale_fields: stale_fields} = payload, socket) do
    push(socket, event, payload)

    if stale_fields |> Enum.member?("member_permissions") do
      # If hub member permissions change, everyone should flush their new permissions into presence so that other
      # clients can correctly authorized their actions.
      broadcast_presence_update(socket)
    end

    {:noreply, socket}
  end

  def handle_out("block", %{"session_id" => session_id, :from_session_id => from_session_id}, socket) do
    socket =
      if socket.assigns.session_id === session_id do
        socket
        |> assign(:blocked_by_session_ids, socket.assigns.blocked_by_session_ids |> Map.put(from_session_id, true))
        |> assign_has_blocks
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_out("unblock", %{"session_id" => session_id, :from_session_id => from_session_id}, socket) do
    socket =
      if socket.assigns.session_id === session_id do
        socket
        |> assign(:blocked_by_session_ids, socket.assigns.blocked_by_session_ids |> Map.delete(from_session_id))
        |> assign_has_blocks
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_out("message" = event, %{from_session_id: from_session_id} = payload, socket) do
    blocked_session_ids = socket.assigns.blocked_session_ids
    blocked_by_session_ids = socket.assigns.blocked_by_session_ids

    if !Map.has_key?(blocked_session_ids, from_session_id) and !Map.has_key?(blocked_by_session_ids, from_session_id) do
      push(socket, event, payload |> payload_without_from)
    end

    {:noreply, socket}
  end

  defp maybe_push_naf(socket, event, payload, false = _block_naf, blocked_session_ids, blocked_by_session_ids)
       when blocked_session_ids === %{} and blocked_by_session_ids === %{} do
    push(socket, event, payload)
    {:noreply, socket}
  end

  defp maybe_push_naf(
         socket,
         event,
         %{from_session_id: from_session_id} = payload,
         false = _block_naf,
         blocked_session_ids,
         blocked_by_session_ids
       ) do
    if !Map.has_key?(blocked_session_ids, from_session_id) and !Map.has_key?(blocked_by_session_ids, from_session_id) do
      push(socket, event, payload)
    end

    {:noreply, socket}
  end

  # Sockets can block NAF as an optimization, eg iframe embeds do not need NAF messages until user clicks load
  defp maybe_push_naf(socket, _event, _payload, true = _block_naf, _blocked_session_ids, _blocked_by_session_ids) do
    {:noreply, socket}
  end

  defp spawn_permitted?(template, socket) do
    account = Guardian.Phoenix.Socket.current_resource(socket)
    hub = socket |> hub_for_socket

    cond do
      template |> String.ends_with?("-avatar") -> true
      template |> String.ends_with?("-media") -> account |> can?(spawn_and_move_media(hub))
      template |> String.ends_with?("-camera") -> account |> can?(spawn_camera(hub))
      template |> String.ends_with?("-drawing") -> account |> can?(spawn_drawing(hub))
      template |> String.ends_with?("-pen") -> account |> can?(spawn_drawing(hub))
      template |> String.ends_with?("-emoji") -> account |> can?(spawn_emoji(hub))
      # We want to forbid messages if they fall through the above list of template suffixes
      true -> false
    end
  end

  defp handle_entry_mode_change(socket, entry_mode) do
    hub = socket |> hub_for_socket
    account = Guardian.Phoenix.Socket.current_resource(socket)
    token = Guardian.Phoenix.Socket.current_token(socket)

    if account |> Account.external(token) |> can?(close_hub(hub)) do
      hub
      |> Hub.changeset_for_entry_mode(entry_mode)
      |> Repo.update!()
      |> Repo.preload(Hub.hub_preloads())
      |> broadcast_hub_refresh!(socket, ["entry_mode"])
    end

    {:noreply, socket}
  end

  defp with_account(socket, handler) do
    case Guardian.Phoenix.Socket.current_resource(socket) do
      %Account{} = account ->
        handler.(account)
        {:reply, {:ok, %{}}, socket}

      _ ->
        # client should have signed-in at this point,
        # so if we still don't have an account, it must have been an invalid token
        {:reply, {:error, %{reason: :invalid_token}}, socket}
    end
  end

  def handle_info({:begin_tracking, session_id, _hub_sid}, socket) do
    {:ok, _} = Presence.track(socket, session_id, socket |> presence_meta_for_socket)
    push(socket, "presence_state", socket |> Presence.list())

    {:noreply, socket}
  end

  def handle_info(:close_channel, socket) do
    GenServer.cast(self(), :close)
    {:noreply, socket}
  end

  def handle_info(_message, socket) do
    {:noreply, socket}
  end

  defp perform_pin!(object_id, gltf_node, account, socket) do
    hub = socket |> hub_for_socket
    RoomObject.perform_pin!(hub, account, %{object_id: object_id, gltf_node: gltf_node})
    broadcast_pinned_media(socket, object_id, gltf_node)
  end

  def terminate(_reason, socket) do
    # enable_terminate_actions is set to false during tests. Since the GenServer is forcefully
    # terminated when a test ends, we want to avoid running into an error that would happen if we
    # invoked a DB mutation during termination.
    if Application.get_env(:ret, __MODULE__)[:enable_terminate_actions] !== false do
      socket
      |> SessionStat.stat_query_for_socket()
      |> Repo.update_all(set: [ended_at: NaiveDateTime.utc_now()])
    end

    :ok
  end

  defp set_presence_flag(socket, flag, value) do
    socket = socket |> assign(flag, value) |> broadcast_presence_update
    {:noreply, socket}
  end

  defp broadcast_presence_update(socket) do
    Presence.update(socket, socket.assigns.session_id, socket |> presence_meta_for_socket)
    socket
  end

  defp broadcast_pinned_media(socket, object_id, gltf_node) do
    broadcast!(socket, "pin", %{object_id: object_id, gltf_node: gltf_node, pinned_by: socket.assigns.session_id})
  end

  # Broadcasts the full hub info as well as an (optional) list of specific fields which
  # clients should consider stale and need to be updated in client state from the new
  # hub info
  #
  # Note this doesn't necessarily mean the fields have changed.
  #
  # For example, if the scene needs to be refreshed, this message indicates that by including
  # "scene" in the list of stale fields.
  defp broadcast_hub_refresh!(hub, socket, stale_fields) do
    account = Guardian.Phoenix.Socket.current_resource(socket)

    response =
      HubView.render("show.json", %{hub: hub, embeddable: account |> can?(embed_hub(hub))})
      |> Map.put(:session_id, socket.assigns.session_id)
      |> Map.put(:stale_fields, stale_fields)

    broadcast!(socket, "hub_refresh", response)
  end

  defp presence_meta_for_socket(socket) do
    hub = socket |> hub_for_socket
    account = Guardian.Phoenix.Socket.current_resource(socket)
    token = Guardian.Phoenix.Socket.current_token(socket)

    socket.assigns
    |> Map.put(:roles, hub |> Hub.roles_for_account(account))
    |> Map.put(:permissions, hub |> Hub.perms_for_account(account |> Account.external(token)))
    |> Map.take([:presence, :profile, :context, :roles, :permissions, :streaming, :recording, :hand_raised, :typing])
  end

  defp join_with_hub(%Hub{entry_mode: :deny}, _account, _socket, _context, _params) do
    {:error, %{message: "Hub no longer accessible", reason: "closed"}}
  end

  # Join denied based upon account requirement
  defp join_with_hub(
         %Hub{},
         nil = _account,
         _socket,
         _context,
         %{
           has_perms_token: false
         }
       ),
       do: deny_join()

  defp join_with_hub(%Hub{} = hub, account, socket, context, params) do
    hub = hub |> Hub.ensure_host()
    hub =
      if context["embed"] && !hub.embedded do
        hub
        |> Hub.changeset_for_seen_embedded_hub()
        |> Repo.update!()
      else
        hub
      end

    # Each channel connection needs to be aware if there are, or ever have been,
    # embeddings of this hub (see internal_naf_event_for/2)
    socket = socket |> assign(:has_embeds, hub.embedded)

    push_subscription_endpoint = params["push_subscription_endpoint"]

    is_push_subscribed =
      push_subscription_endpoint &&
        hub.web_push_subscriptions |> Enum.any?(&(&1.endpoint == push_subscription_endpoint))

    socket = Guardian.Phoenix.Socket.put_current_resource(socket, account)
    socket = Guardian.Phoenix.Socket.put_current_token(socket, params["auth_token"])

    with socket <-
           socket
           |> assign(:hub_sid, hub.hub_sid)
           |> assign(:presence, :lobby),
         response <- HubView.render("show.json", %{hub: hub, embeddable: account |> Account.external(params["auth_token"]) |> can?(embed_hub(hub))}) do

      response =
        response
        |> Map.put(:session_id, socket.assigns.session_id)
        |> Map.put(:session_token, socket.assigns.session_id |> Ret.SessionToken.token_for_session())
        |> Map.put(:subscriptions, %{web_push: is_push_subscribed})

      existing_stat_count =
        socket
        |> SessionStat.stat_query_for_socket()
        |> Repo.all()
        |> length

      unless existing_stat_count > 0 do
        with session_id <- socket.assigns.session_id,
             started_at <- socket.assigns.started_at,
             stat_attrs <- %{session_id: session_id, started_at: started_at},
             changeset <- %SessionStat{} |> SessionStat.changeset(stat_attrs) do
          Repo.insert(changeset)
        end
      end

      send(self(), {:begin_tracking, socket.assigns.session_id, hub.hub_sid})

      # Send join push notification if this is the first joiner
      if Presence.list(socket.topic) |> Enum.count() == 0 do
        Task.start_link(fn -> hub |> Hub.send_push_messages_for_join(push_subscription_endpoint) end)
      end

      Statix.increment("ret.channels.hub.joins.ok")

      {:ok, response, socket}
    end
  end

  defp deny_join do
    {:error, %{message: "Join denied", reason: "join_denied"}}
  end

  defp handle_entered_event(socket, payload) do
    stat_attributes = [entered_event_payload: payload, entered_event_received_at: NaiveDateTime.utc_now()]

    # Flip context to have HMD if entered with display type
    socket =
      with %{"entryDisplayType" => display} when is_binary(display) and display != "Screen" <- payload,
           %{context: context} when is_map(context) <- socket.assigns do
        socket |> assign(:context, context |> Map.put("hmd", true))
      else
        _ -> socket
      end

    socket
    |> SessionStat.stat_query_for_socket()
    |> Repo.update_all(set: stat_attributes)

    context = socket.assigns.context || %{}

    socket
    |> assign(:presence, :room)
    |> assign(:context, context |> Map.delete("entering"))
    |> broadcast_presence_update
  end

  defp handle_max_occupant_update(socket, occupant_count) do
    socket
    |> hub_for_socket
    |> Hub.changeset_for_new_seen_occupant_count(occupant_count)
    |> Repo.update!()

    socket
  end

  defp handle_object_spawned(socket, object_type) do
    socket
    |> hub_for_socket
    |> Hub.changeset_for_new_spawned_object_type(object_type)
    |> Repo.update!()

    socket
  end

  defp hub_for_socket(socket) do
    Repo.get_by(Hub, hub_sid: socket.assigns.hub_sid) |> Repo.preload([:hub_role_memberships])
  end

  defp payload_with_from(payload, socket) do
    payload |> Map.put(:from_session_id, socket.assigns.session_id)
  end

  defp payload_without_from(payload) do
    payload |> Map.delete(:from_session_id)
  end

  defp assign_has_blocks(socket) do
    has_blocks =
      socket.assigns.blocked_session_ids |> Enum.any?() || socket.assigns.blocked_by_session_ids |> Enum.any?()

    socket |> assign(:has_blocks, has_blocks)
  end

  # Normally, naf and nafr messages are sent as is. However, if this connection is blocking users,
  # has been blocked, or the hub itself has been seen in an iframe, we need to potentially filter
  # NAF messages. As such, we internally route messages via an intercepted handle_out for filtering.
  # This is done via the intercepted maybe-nafr and maybe-naf events.
  #
  # We avoid doing this in general because it's extremely expensive, since it re-encodes all outgoing messages.
  defp internal_naf_event_for("nafr", %Phoenix.Socket{assigns: %{has_blocks: false, has_embeds: false}}), do: "nafr"
  defp internal_naf_event_for("naf", %Phoenix.Socket{assigns: %{has_blocks: false, has_embeds: false}}), do: "naf"
  defp internal_naf_event_for("nafr", _socket), do: "maybe-nafr"
  defp internal_naf_event_for("naf", _socket), do: "maybe-naf"
end
