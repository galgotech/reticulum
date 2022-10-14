defmodule Ret.JanusLoadStatus do
  use Cachex.Warmer
  use Retry
  def interval, do: :timer.seconds(15)

  require Logger

  def execute(_state) do
    if module_config(:janus_service_name) == "" do
      {:ok, [{:host_to_ccu, [{module_config(:default_janus_host), 0}]}]}
    else
      with pods when pods != [] <- get_dialog_pods() do
        IO.inspect(pods)
        {:ok, [{:host_to_ccu, pods}]}
      else
        _ ->
          Logger.warn("falling back to default_janus_host because get_dialog_pods() returned []")
          {:ok, [{:host_to_ccu, [{module_config(:default_janus_host), 0}]}]}
      end
    end
  end

  defp get_dialog_pods() do
    try do
      host_names = [
        module_config(:dialog_host),
      ]

      for host_name <- host_names do
        hosts =
          host_name
          |> String.to_charlist()
          |> :inet_res.lookup(:in, :a)
          |> Enum.map(fn {a, b, c, d} -> "#{a}.#{b}.#{c}.#{d}" end)

        for host <- hosts do
          port = module_config(:janus_port)
          hackney = if Mix.env() == :prod do [] else [:insecure] end
          %{body: body} = HTTPoison.get!("https://#{host}:#{port}/meta", [], hackney: hackney)
          body_json = body |> Poison.decode!()

          # The cache key we construct here is a set of meta data that will be parsed by the dialog ingress proxy (dip),
          # which will decide how to route dialog connections based on this information.
          ret_max_room_size = Ret.AppConfig.get_cached_config_value("features|max_room_size")
          meta_data_str = "#{host}|#{ret_max_room_size}"
          encoded_meta_data = Base.encode32(meta_data_str, case: :lower, padding: false)
          cache_key = "#{encoded_meta_data}.#{module_config(:janus_service_name)}"

          #current_load = body_json["cap"]
          current_load = body_json["ccu"]

          {cache_key, current_load}
        end
      end
    rescue
      exception ->
        # This should only really occur in disaster scenarios,
        # if the request to the dialog endpoint fails, or it returns an invalid response.
        Logger.warn(inspect(exception))
        []
    end
  end

  defp module_config(key) do
    Application.get_env(:ret, __MODULE__)[key]
  end
end
