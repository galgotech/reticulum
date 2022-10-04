defmodule RetWeb.Router do
  use RetWeb, :router
  use Plug.ErrorHandler
  use Sentry.Plug

  pipeline :secure_headers do
    plug(:put_secure_browser_headers)
    plug(RetWeb.Plugs.AddCSP)
  end

  pipeline :strict_secure_headers do
    plug(:put_secure_browser_headers)
    plug(RetWeb.Plugs.AddCSP, strict: true)
  end

  pipeline :ssl_only do
    plug(Plug.SSL, hsts: true, rewrite_on: [:x_forwarded_proto])
  end

  pipeline :parsed_body do
    plug(
      Plug.Parsers,
      parsers: [:urlencoded, :multipart, :json],
      pass: ["*/*"],
      json_decoder: Phoenix.json_library(),
      length: 157_286_400,
      read_timeout: 300_000
    )
  end

  pipeline :rate_limit do
    plug(RetWeb.Plugs.RateLimit)
  end

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:put_layout, false)
  end

  pipeline :api do
    plug(:accepts, ["json"])
  end

  pipeline :forbid_disabled_accounts do
    plug(RetWeb.Plugs.ForbidDisabledAccounts)
  end

  pipeline :auth_required do
    plug(RetWeb.Guardian.AuthPipeline)
    plug(RetWeb.Canary.AuthorizationPipeline)
    plug(RetWeb.Plugs.ForbidDisabledAccounts)
  end

  pipeline :canonicalize_domain do
    plug(RetWeb.Plugs.RedirectToMainDomain)
  end

  scope "/health", RetWeb do
    get("/", HealthController, :index)
  end

  scope "/api", RetWeb do
    pipe_through(
      [:secure_headers, :parsed_body, :api] ++
        if(Mix.env() == :prod, do: [:ssl_only, :canonicalize_domain], else: []) ++
        [:auth_required]
    )

    scope "/v1", as: :api_v1 do
      get("/meta", Api.V1.MetaController, :show)
      get("/avatars/:id/base.gltf", Api.V1.AvatarController, :show_base_gltf)
      get("/avatars/:id/avatar.gltf", Api.V1.AvatarController, :show_avatar_gltf)
    end

    scope "/v1", as: :api_v1 do
      pipe_through([:forbid_disabled_accounts])
      resources("/hubs", Api.V1.HubController, only: [:create, :delete])
    end

    # Must be defined before :show for scenes
    scope "/v1", as: :api_v1 do
      get("/scenes/projectless", Api.V1.SceneController, :index_projectless)
    end

    scope "/v1", as: :api_v1 do
      resources("/media/search", Api.V1.MediaSearchController, only: [:index])
      resources("/avatars", Api.V1.AvatarController, only: [:show])

      resources("/scenes", Api.V1.SceneController, only: [:show])
    end

    scope "/v1", as: :api_v1 do
      resources("/scenes", Api.V1.SceneController, only: [:create, :update])
      resources("/avatars", Api.V1.AvatarController, only: [:create, :update, :delete])
      resources("/hubs", Api.V1.HubController, only: [:update])
      resources("/assets", Api.V1.AssetsController, only: [:create, :delete])

      resources("/projects", Api.V1.ProjectController, only: [:index, :show, :create, :update, :delete]) do
        post("/publish", Api.V1.ProjectController, :publish)
        resources("/assets", Api.V1.ProjectAssetsController, only: [:index, :create, :delete])
      end
    end
  end

  # Directly accessible APIs.
  # Permit direct file uploads without intermediate ALB/Cloudfront/CDN proxying.
  scope "/api", RetWeb do
    pipe_through(
      [:secure_headers, :parsed_body, :api] ++
        if(Mix.env() == :prod, do: [:ssl_only], else: []) ++
        [:auth_required]
    )

    scope "/v1", as: :api_v1 do
      resources("/media", Api.V1.MediaController, only: [:create])
    end
  end

  scope "/", RetWeb do
    pipe_through(
      [:strict_secure_headers, :parsed_body, :browser] ++
        if(Mix.env() == :prod, do: [:ssl_only], else: [])
    )

    head("/files/:id", FileController, :head)
    get("/files/:id", FileController, :show)
  end

  scope "/", RetWeb do
    pipe_through(
      [:secure_headers, :parsed_body, :browser] ++
        if(Mix.env() == :prod, do: [:ssl_only, :canonicalize_domain], else: [])
    )

    get("/*path", PageController, only: [:index])
  end
end
