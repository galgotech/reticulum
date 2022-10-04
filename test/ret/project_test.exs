defmodule Ret.ProjectTest do
  use Ret.DataCase, async: true

  alias Ret.{Account, DummyData, OwnedFile, Repo, Project, Storage}

  import Ret.TestHelpers,
    only: [create_account: 1, create_owned_file: 2, generate_temp_owned_file: 1]

  @sample_domain "https://hubs.local"

  @spec create_project_with_sample_owned_files(Account.t()) :: Project.t()
  defp create_project_with_sample_owned_files(%Account{} = account) do
    project_owned_file = create_owned_file(account, @sample_domain)
    thumbnail_owned_file = generate_temp_owned_file(account)

    %Project{}
    |> Project.changeset(account, project_owned_file, thumbnail_owned_file, %{name: DummyData.project_name()})
    |> Repo.insert!()
    |> Repo.preload([:project_owned_file])
  end

  @spec projects :: [Project.t()]
  defp projects,
    do:
      Project
      |> Repo.all()
      |> Repo.preload([:project_owned_file])
end
