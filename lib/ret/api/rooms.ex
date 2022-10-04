defmodule Ret.Api.Rooms do
  @moduledoc "Functions for accessing rooms in an authenticated way"

  alias Ret.{Account, Hub, Repo}
  alias RetWeb.Api.V1.HubView

  import Canada, only: [can?: 2]

  defp try_do_update_room({:error, reason}, _) do
    {:error, reason}
  end

  defp broadcast_hub_refresh(hub, subject, stale_fields) do
    payload =
      HubView.render("show.json", %{
        hub: hub,
        embeddable: subject |> can?(embed_hub(hub))
      })
      |> Map.put(:stale_fields, stale_fields)

    RetWeb.Endpoint.broadcast("hub:" <> hub.hub_sid, "hub_refresh", payload)
  end
end
