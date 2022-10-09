defmodule Ret.Repo.Migrations.CreateHubsTable do
  use Ecto.Migration

  def change do
    create table(:hubs, primary_key: false) do
      add(:hub_id, :bigint, null: false, default: fragment("unique_rowid()"), primary_key: true)
      add(:hub_sid, :string)
      add(:slug, :string, null: false)
      add(:name, :string, null: false)
      add(:default_environment_gltf_bundle_url, :string, null: true)

      timestamps()
    end

    create(index(:hubs, [:hub_sid], unique: true))
  end
end
