defmodule Ret.Repo.Migrations.ExtendSceneColumn do
  use Ecto.Migration

  def change do
    alter table("hubs") do
      modify(:default_environment_gltf_bundle_url, :string, null: true, size: 2048)
    end
  end
end
