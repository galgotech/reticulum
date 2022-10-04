defmodule Ret.Guardian do
  @moduledoc """
  This is our primary, long-lived, authenticion token. We used to sign clients in and associate them with a Ret.Account.
  """
  use Guardian, otp_app: :ret, secret_fetcher: Ret.PermsTokenSecretFetcher, allowed_algos: ["RS512"]
  import Ecto.Query

  alias Ret.{Account, AccountExternal, Repo}

  def subject_for_token(%Account{} = account, _claims) do
    {:ok, account.account_id |> to_string}
  end

  def subject_for_token(_, _) do
    {:error, "Not found"}
  end

  def resource_from_claims(%{"sub" => external_id, "iat" => issued_at, "email" => email, "role" => role}) do
    external_id |> Account.account_for_login_external_id()

    Account
    |> where([a], a.external_id == ^external_id)
    |> Repo.one()
    |> result_for_account
  end

  def resource_from_claims(_claims) do
    {:error, "No subject"}
  end

  defp result_for_account(%Account{} = account), do: {:ok, account}
  defp result_for_account(nil), do: {:error, "Not found"}
end
