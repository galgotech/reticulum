defmodule Ret.Repo.Migrations.CreateAccount do
  use Ecto.Migration

  def change do
    create table(:accounts, primary_key: false) do
      add(:account_id, :bigint, null: false, default: fragment("unique_rowid()"), primary_key: true)
      add(:external_id, :string)

      timestamps()
    end

    create(index(:accounts, [:external_id], unique: true))
  end
end
