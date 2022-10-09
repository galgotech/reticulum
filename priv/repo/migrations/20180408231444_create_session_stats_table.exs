defmodule Ret.Repo.Migrations.CreateSessionStatsTable do
  use Ecto.Migration

  @max_year 2030

  def up do
    create table(:session_stats, primary_key: false) do
      add(:session_id, :uuid, null: false)
      add(:started_at, :utc_datetime, null: false)
      add(:ended_at, :utc_datetime)
      add(:entered_event_payload, :jsonb)
      add(:entered_event_received_at, :utc_datetime)
    end
  end

  def down do
    drop(table(:session_stats))
  end
end
