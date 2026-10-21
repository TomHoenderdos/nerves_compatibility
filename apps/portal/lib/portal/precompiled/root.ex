defmodule Portal.Precompiled.Root do
  @moduledoc "The root document: which keys may sign batches and roots, and the thresholds."
  alias Portal.Precompiled.Keys

  @spec payload(String.t(), binary(), DateTime.t()) :: binary()
  def payload(keyid, public, %DateTime{} = expires) do
    JSON.encode!(%{
      "version" => 1,
      "expires" => DateTime.to_iso8601(expires),
      "keys" => %{
        keyid => %{"type" => "ed25519", "public" => Base.url_encode64(public, padding: false)}
      },
      "roles" => %{
        "root" => %{"keyids" => [keyid], "threshold" => 1},
        "batch" => %{"keyids" => [keyid], "threshold" => 1}
      }
    })
  end

  @doc "The signed root envelope bytes next to the signing key, as served."
  @spec load() :: {:ok, binary()} | {:error, :no_root}
  def load do
    with path when is_binary(path) <- Keys.root_path(),
         {:ok, body} <- File.read(path) do
      {:ok, body}
    else
      _ -> {:error, :no_root}
    end
  end
end
