defmodule Portal.Accounts.IdentityProvider do
  @moduledoc """
  A provider that proves who someone is through the OAuth device flow.

  The modules are looked up through config so controller tests can drive the
  whole sign-in flow without hex.pm or github.com.
  """

  alias Portal.Accounts.Identity

  @callback start_device_flow() :: {:ok, map()} | {:error, atom()}
  @callback verify_device(String.t()) ::
              {:ok, Identity.t()} | {:pending, atom()} | {:error, atom()}

  @spec module(Identity.provider()) :: module()
  def module(provider) when provider in [:hex, :github] do
    :portal
    |> Application.get_env(:identity_providers, %{hex: Portal.HexPm, github: Portal.GitHub})
    |> Map.fetch!(provider)
  end
end
