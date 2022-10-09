defmodule Ret.AccountExternal do

  alias Ret.{AccountExternal}

  defstruct account_id: 0, is_admin: true, state: :enabled

  def perms(%AccountExternal{} = account) do
    %{

    }
  end

end


defmodule Ret.Account do
  use Ecto.Schema
  import Ecto.Query
  import Ecto.Changeset

  alias Ret.{Repo, Account, Guardian, AccountExternal}

  import Canada, only: [can?: 2]

  @type t :: %__MODULE__{}

  @schema_prefix "ret0"
  @primary_key {:account_id, :id, autogenerate: false}

  schema "accounts" do
    field(:external_id, :string)
    has_many(:owned_files, Ret.OwnedFile, foreign_key: :account_id)
    has_many(:created_hubs, Ret.Hub, foreign_key: :created_by_account_id)
    has_many(:projects, Ret.Project, foreign_key: :created_by_account_id)
    has_many(:assets, Ret.Asset, foreign_key: :account_id)
    timestamps()
  end

  def account_for_login_external_id(external_id) do
    account =
      Account
      |> where([a], a.external_id == ^external_id)
      |> Repo.one()

    cond do
      account == nil ->
          %Account{external_id: external_id}
          |> cast(%{}, [:external_id])
          |> unique_constraint(:external_id)
          |> Repo.insert!(on_conflict: :nothing)
      true -> nil
    end
  end

  def external(%Account{} = account) do
    %AccountExternal{account_id: account.account_id}
  end

  # defstruct email: "", account_id: "", is_admin: false, state: :disabled

end
