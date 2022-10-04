defmodule Ret.SceneTest do
  use Ret.DataCase, async: true

  alias Ret.{Account, DummyData, OwnedFile, Repo, Scene, Storage}

  import Ret.TestHelpers,
    only: [create_account: 1, create_owned_file: 2, generate_temp_owned_file: 1]

  @sample_domain "https://hubs.local"

  @spec create_scene_with_sample_owned_files(Account.t()) :: Scene.t()
  defp create_scene_with_sample_owned_files(%Account{} = account) do
    model_owned_file = create_owned_file(account, File.read!("test/fixtures/test.glb"))
    screenshot_owned_file = generate_temp_owned_file(account)
    scene_owned_file = create_owned_file(account, @sample_domain)

    %Scene{}
    |> Scene.changeset(account, model_owned_file, screenshot_owned_file, scene_owned_file, %{
      name: DummyData.scene_name()
    })
    |> Repo.insert!()
  end

  @spec scenes :: [Scene.t()]
  defp scenes,
    do:
      Scene
      |> Repo.all()
      |> Repo.preload([:model_owned_file, :scene_owned_file])
end
