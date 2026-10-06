defmodule PortalWeb.ProviderAuthController.UnknownProvider do
  @moduledoc """
  `/auth/:provider/...` named a provider this app does not know.

  Raised rather than rendered directly, so it 404s the same way a missing
  route or a missing record does elsewhere -- caught by the endpoint, not a
  controller-local render. `assert_error_sent 404` needs an error to have
  actually happened; see `Plug.Exception`'s fallback `Any` implementation,
  which reads `:plug_status` off any exception struct that has it.
  """

  defexception message: "unknown identity provider", plug_status: 404
end
