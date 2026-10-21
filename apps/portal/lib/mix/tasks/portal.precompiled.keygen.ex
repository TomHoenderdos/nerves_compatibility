defmodule Mix.Tasks.Portal.Precompiled.Keygen do
  @shortdoc "Generate the precompiled signing key and a self-signed root.json"
  @moduledoc """
  Writes `signing.key` (mode 0600) and `root.json` into `--out DIR`, prints the
  keyid and public key. Point `PRECOMPILED_SIGNING_KEY` at `DIR/signing.key`
  on the web host, and copy `root.json` into the nerves package at
  `priv/precompiled/root.json`. Refuses to overwrite an existing key.

      mix portal.precompiled.keygen --out /etc/ncc/precompiled
  """
  use Mix.Task
  alias Portal.Precompiled.{Envelope, Keys, Root}

  @impl true
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [out: :string, years: :integer])
    dir = opts[:out] || Mix.raise("--out DIR is required")
    key_path = Path.join(dir, "signing.key")
    if File.exists?(key_path), do: Mix.raise("#{key_path} exists; refusing to overwrite")

    key = Keys.generate()
    Keys.write!(key_path, key)
    expires = DateTime.add(DateTime.utc_now(), 365 * (opts[:years] || 1), :day)
    root = Root.payload(key.keyid, key.public, expires)

    File.write!(
      Path.join(dir, "root.json"),
      JSON.encode!(Envelope.sign(root, [{key.keyid, key.private}]))
    )

    Mix.shell().info("keyid:  #{key.keyid}")
    Mix.shell().info("public: #{Base.url_encode64(key.public, padding: false)}")
    Mix.shell().info("wrote #{key_path} and #{Path.join(dir, "root.json")}")
  end
end
