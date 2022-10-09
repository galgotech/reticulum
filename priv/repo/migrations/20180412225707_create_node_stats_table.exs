defmodule Ret.Repo.Migrations.NodeStatsTable do
  use Ecto.Migration

  @max_year 2022

  def up do
    create table( :node_stats, primary_key: false) do
      add(:node_id, :string, null: false)
      add(:measured_at, :utc_datetime, null: false)
      add(:present_sessions, :integer)
      add(:present_rooms, :integer)
    end
  end

  def down do
    drop(table(:node_stats))
  end
end
