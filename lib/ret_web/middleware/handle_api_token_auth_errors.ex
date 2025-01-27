defmodule RetWeb.Middleware.HandleApiTokenAuthErrors do
  @moduledoc false

  @behaviour Absinthe.Middleware

  import RetWeb.Middleware.PutErrorResult, only: [put_error_result: 3]

  def call(%{state: :resolved} = resolution, _) do
    resolution
  end

  # Don't enforce authentication on introspection queries
  # See Absinthe.Introspection.type?
  # https://github.com/absinthe-graphql/absinthe/blob/cdb8c39beb6a79b03a5095fffbe761e0dd9918ac/lib/absinthe/introspection.ex#L106
  def call(%{parent_type: %{name: "__" <> _}} = resolution, _) do
    resolution
  end

  def call(%{context: %{api_token_auth_errors: errors}} = resolution, _) when is_list(errors) and length(errors) > 0 do
    {type, reason} = Enum.at(errors, 0)
    put_error_result(resolution, type, reason)
  end
end
