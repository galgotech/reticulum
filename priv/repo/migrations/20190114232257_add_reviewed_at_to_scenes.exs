defmodule Ret.Repo.Migrations.AddReviewedAtToScenes do
  use Ecto.Migration

  def change do
    alter table("scenes") do
      add(:reviewed_at, :utc_datetime, null: true)
    end

    create(index(:scenes, [:reviewed_at]))
  end
end
