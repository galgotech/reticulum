defmodule Ret.Repo.Migrations.AddCachedFiles do
  use Ecto.Migration

  def change do
    create table(:cached_files, primary_key: false) do
      add(:cached_file_id, :bigint, default: fragment("unique_rowid()"), primary_key: true)
      add(:cache_key, :string, null: false)
      add(:file_uuid, :string, null: false)
      add(:file_key, :string, null: false)
      add(:file_content_type, :string, null: false)

      timestamps()
    end

    create(index(:cached_files, [:cache_key], unique: true))
  end
end
