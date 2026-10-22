defmodule Portal.Precompiled.Keys do
  @moduledoc """
  The portal's online Ed25519 signing key: generation, the key file next to
  which `root.json` lives, and the keyid convention (hex SHA-256 of the 32
  public key bytes). The path comes from `config :portal, :precompiled_signing,
  key_path:` (`PRECOMPILED_SIGNING_KEY`).
  """

  @type t :: %{keyid: String.t(), public: binary(), private: binary()}

  @spec generate() :: t()
  def generate do
    {public, private} = :crypto.generate_key(:eddsa, :ed25519)
    %{keyid: keyid(public), public: public, private: private}
  end

  @spec keyid(binary()) :: String.t()
  def keyid(public) when byte_size(public) == 32,
    do: Base.encode16(:crypto.hash(:sha256, public), case: :lower)

  @spec key_path() :: Path.t() | nil
  def key_path, do: Application.get_env(:portal, :precompiled_signing, [])[:key_path]

  @spec root_path() :: Path.t() | nil
  def root_path do
    case key_path() do
      nil -> nil
      path -> Path.join(Path.dirname(path), "root.json")
    end
  end

  @spec write!(Path.t(), t()) :: :ok
  def write!(path, %{public: public, private: private}) do
    dir = Path.dirname(path)
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)

    json =
      JSON.encode!(%{"type" => "ed25519", "public" => b64(public), "private" => b64(private)})

    File.touch!(path)
    File.chmod!(path, 0o600)
    File.write!(path, json)
    :ok
  end

  @spec load() :: {:ok, t()} | {:error, :no_key | :unreadable}
  def load do
    case key_path() do
      nil -> {:error, :no_key}
      path -> read(path)
    end
  end

  defp read(path) do
    with {:ok, body} <- File.read(path),
         {:ok, %{"type" => "ed25519", "public" => pub, "private" => priv}} <- JSON.decode(body),
         {:ok, public} <- Base.url_decode64(pub, padding: false),
         {:ok, private} <- Base.url_decode64(priv, padding: false),
         true <- byte_size(public) == 32 and byte_size(private) == 32 do
      {:ok, %{keyid: keyid(public), public: public, private: private}}
    else
      _ -> {:error, :unreadable}
    end
  end

  defp b64(bin), do: Base.url_encode64(bin, padding: false)
end
