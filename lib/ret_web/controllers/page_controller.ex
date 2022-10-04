defmodule RetWeb.PageController do
  use RetWeb, :controller

  alias Ret.{
    Repo,
    HttpUtils,
    Hub
  }

  alias Plug.Conn
  import Ret.ConnUtils

  ##
  # NOTE: In addition to adding a route, you must add static html pages to the page_origin_warmer.ex
  # file in order for them to work.
  ##

  @configurable_assets %{
    app_config_favicon: {"favicon.ico", "images|favicon", "image/x-icon"},
    app_config_app_icon: {"app-icon.png", "images|app_icon", "image/png"},
    app_config_app_thumbnail: {"app-thumbnail.png", "images|app_thumbnail", "image/png"}
  }

  @configurable_asset_files @configurable_assets |> Map.values() |> Enum.map(&elem(&1, 0))
  @configurable_asset_paths @configurable_asset_files |> Enum.map(&"/#{&1}")

  def call(conn, _params) do
    # assets_host = RetWeb.Endpoint.config(:assets_url)[:host]
    # is_configurable_asset = @configurable_asset_paths |> Enum.any?(&(&1 === conn.request_path))

    cond do
      # matches_host(conn, assets_host) && !is_configurable_asset ->
      #   render_asset(conn)

      true ->
        case conn.request_path do
          "/thumbnail/" <> _ -> imgproxy_proxy(conn)
          "/http://" <> _ -> cors_proxy(conn)
          "/https://" <> _ -> cors_proxy(conn)
          _ -> render_for_path(conn.request_path, conn.query_params, conn)
        end
    end
  end

  def render_for_path("/" <> path, params, conn) do
    embed_token = params["embed_token"]

    [_, hub_sid | subresource] = path |> String.split("/")

    hub = Hub |> Repo.get_by(hub_sid: hub_sid)

    if embed_token && hub.embed_token != embed_token do
      conn |> send_resp(404, "Invalid embed token.")
    else
      conn =
        if embed_token do
          # Allow iframe embedding
          conn |> delete_resp_header("x-frame-options")
        else
          conn
        end

      render_hub_content(conn, hub, subresource |> Enum.at(0))
    end
  end

  def render_hub_content(conn, hub, "objects.gltf") do
    room_gltf = hub.hub_id |> Ret.RoomObject.gltf_for_hub_id() |> Poison.encode!()

    conn
    |> put_resp_header("content-type", "model/gltf+json; charset=utf-8")
    |> send_resp(200, room_gltf)
  end

  defp imgproxy_proxy(%Conn{request_path: "/thumbnail/" <> encoded_url, query_string: qs} = conn) do
    with imgproxy_url <- Application.get_env(:ret, RetWeb.Endpoint)[:imgproxy_url],
         [scheme, port, host] = [:scheme, :port, :host] |> Enum.map(&Keyword.get(imgproxy_url, &1)),
         %{"w" => width, "h" => height} <- qs |> URI.decode_query() do
      thumbnail_url = "#{scheme}://#{host}:#{port}//auto/#{width}/#{height}/sm/1/#{encoded_url}"

      opts =
        ReverseProxyPlug.init(
          upstream: thumbnail_url,
          client_options: [ssl: [{:versions, [:"tlsv1.2"]}]]
        )

      body = ReverseProxyPlug.read_body(conn)

      %Conn{}
      |> Map.merge(conn)
      # Need to strip path_info since proxy plug reads it
      |> Map.put(:path_info, [])
      |> ReverseProxyPlug.request(body, opts)
      |> ReverseProxyPlug.response(conn, opts)
    else
      _ ->
        conn |> send_resp(401, "Bad request")
    end
  end

  defp cors_proxy(%Conn{request_path: "/" <> url, query_string: ""} = conn), do: cors_proxy(conn, url)
  defp cors_proxy(%Conn{request_path: "/" <> url, query_string: qs} = conn), do: cors_proxy(conn, "#{url}?#{qs}")

  defp cors_proxy(conn, url) do
    %URI{authority: authority, host: host} = uri = URI.parse(url)

    resolved_ip = HttpUtils.resolve_ip(host)

    if HttpUtils.internal_ip?(resolved_ip) do
      conn |> send_resp(401, "Bad request.")
    else
      # We want to ensure that the URL we request hits the same IP that we verified above,
      # so we replace the host with the IP address here and use this url to make the proxy request.
      ip_url = URI.to_string(HttpUtils.replace_host(uri, resolved_ip))

      # Disallow CORS proxying unless request was made to the cors proxy url
      cors_proxy_url = Application.get_env(:ret, RetWeb.Endpoint)[:cors_proxy_url]
      [cors_scheme, cors_port, cors_host] = [:scheme, :port, :host] |> Enum.map(&Keyword.get(cors_proxy_url, &1))
      is_cors_proxy_url = cors_scheme == Atom.to_string(conn.scheme) && cors_host == conn.host && cors_port == conn.port

      if is_cors_proxy_url do
        allowed_origins = Application.get_env(:ret, RetWeb.Endpoint)[:allowed_origins] |> String.split(",")

        opts =
          ReverseProxyPlug.init(
            upstream: ip_url,
            allowed_origins: allowed_origins,
            proxy_url: "#{cors_scheme}://#{cors_host}:#{cors_port}",
            # Since we replaced the host with the IP address in ip_url above, we need to force the host
            # used for ssl verification here so that the connection isn't rejected.
            # Note that we have to convert the authority to a charlist, since this uses Erlang's `ssl` module
            # internally, which expects a charlist.
            client_options: [ssl: [{:server_name_indication, to_charlist(authority)}, {:versions, [:"tlsv1.2"]}]],
            preserve_host_header: true
          )

        body = ReverseProxyPlug.read_body(conn)
        is_head = conn |> Conn.get_req_header("x-original-method") == ["HEAD"]

        %Conn{}
        |> Map.merge(conn)
        |> Map.put(
          :method,
          if is_head do
            "HEAD"
          else
            conn.method
          end
        )
        # Need to strip path_info since proxy plug reads it
        |> Map.put(:path_info, [])
        # Since we replaced the host with the IP address in ip_url above, we need to force the host
        # header back to the original authority so that the proxy destination does not reject our request
        |> Conn.put_req_header("host", authority)
        # Some domains disallow access from improper Origins
        |> Conn.delete_req_header("origin")
        |> ReverseProxyPlug.request(body, opts)
        |> ReverseProxyPlug.response(conn, opts)
      else
        conn |> send_resp(401, "Bad request.")
      end
    end
  end

  defp render_asset(conn) do
    static_options = Plug.Static.init(at: "/", from: module_config(:assets_path), gzip: true, brotli: true)
    Plug.Static.call(conn, static_options)
  end

  defp module_config(key), do: Application.get_env(:ret, __MODULE__)[key]
end
