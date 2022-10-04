defmodule RetWeb.HealthController do
  use RetWeb, :controller
  import Ecto.Query

  def index(conn, _params) do
    # Check database
    if module_config(:check_repo) do
      from(h in Ret.Hub, limit: 0) |> Ret.Repo.all()
    end

    # Check room routing
    true = Ret.RoomAssigner.get_available_host("") != nil

    send_resp(conn, 200, "ok")
  end

  defp module_config(key) do
    Application.get_env(:ret, __MODULE__)[key]
  end
end
