defmodule Portal.Test.FakeProvider do
  @moduledoc """
  Stands in for hex.pm and github.com. Controller tests run in the test
  process, so each test scripts its answers with `Process.put/2`.
  """

  @behaviour Portal.Accounts.IdentityProvider

  @impl true
  def start_device_flow do
    Process.get(
      :fake_provider_start,
      {:ok,
       %{
         device_code: "dev",
         user_code: "ABCD-1234",
         verification_uri: "https://example.test/device",
         expires_in: 900,
         interval: 5
       }}
    )
  end

  @impl true
  def verify_device(_device_code),
    do: Process.get(:fake_provider_verify, {:pending, :authorization_pending})
end
