defmodule Ret.Repo.Migrations.CreateAppConfigsTable do
  use Ecto.Migration

  def change do
    create table(:app_configs, primary_key: false) do
      add(:app_config_id, :bigint, default: fragment("unique_rowid()"), primary_key: true)
      add(:key, :string, null: false)
      add(:value, :jsonb)
      add(:owned_file_id, :bigint)

      timestamps()
    end

    create(index(:app_configs, [:key], unique: true))
  end
end
