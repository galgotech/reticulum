defmodule RetWeb.Plugs.ForbidDisabledAccounts do
  import Plug.Conn

  def init([]), do: []

  def call(conn, []) do
    token = Guardian.Plug.current_token(conn)
    account = Guardian.Plug.current_resource(conn) |> Ret.Account.external(token)

    case account do
      %Ret.AccountExternal{state: :disabled} -> conn |> send_resp(401, "") |> halt()
      _ -> conn
    end
  end
end
