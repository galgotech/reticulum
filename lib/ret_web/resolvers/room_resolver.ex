defmodule RetWeb.Resolvers.RoomResolver do
  @moduledoc """
  Resolvers for room queries and mutations via the graphql API
  """
  alias Ret.Hub
  import RetWeb.Resolvers.ResolverError, only: [resolver_error: 2]

  def my_rooms(_parent, _args, _resolutions) do
    resolver_error(:unauthorized, "Unauthorized access")
  end

  def create_room(_parent, _args, _resolutions) do
    resolver_error(:unauthorized, "Unauthorized access")
  end

  def embed_token(_hub, _args, _resolutions) do
    resolver_error(:unauthorized, "Unauthorized access")
  end

  def entry_code(_hub, _args, _resolutions) do
    # The entry code feature has been removed. We return "000000" here to
    # maintain compatibility with older clients.
    {:ok, "000000"}
  end

  def port(_hub, _args, _resolutions) do
    # No permission check needed
    {:ok, Hub.janus_port()}
  end

  def turn(_hub, _args, _resolutions) do
    # No permission check needed
    {:ok, Hub.generate_turn_info()}
  end

  def member_permissions(hub, _args, _resolutions) do
    # No permission check needed
    {:ok, Hub.member_permissions_for_hub_as_atoms(hub)}
  end

  def room_size(hub, _args, _resolutions) do
    # No permission check needed
    {:ok, Hub.room_size_for(hub)}
  end

  def member_count(hub, _args, _resolutions) do
    # No permission check needed
    {:ok, Hub.member_count_for(hub)}
  end

  def lobby_count(hub, _args, _resolutions) do
    # No permission check needed
    {:ok, Hub.lobby_count_for(hub)}
  end

  def scene(hub, _args, _resolutions) do
    # No permission check needed
    {:ok, Hub.scene_or_scene_listing_for(hub)}
  end

  def update_room(_parent, _args, _resolutions) do
    resolver_error(:unauthorized, "Unauthorized access")
  end
end
