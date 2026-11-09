defmodule Mix.Tasks.Portal.Precompiled.OfflineKeygen do
  @shortdoc "Generate the key of the precompiled offline signing role"
  @moduledoc """
  Writes `offline.key` (mode 0600, in a 0700 directory) into `--out DIR` and
  prints its keyid and public key. The key signs bundles' `offline.json`
  (`PRECOMPILED_API.md`, "Offline bundles") once a root names it in its
  `offline` role (`mix portal.precompiled.root_rotate`). Keep it off every
  portal host. Refuses to overwrite an existing key.

      mix portal.precompiled.offline_keygen --out DIR
  """
  use Mix.Task
  alias Portal.Precompiled.Keys

  @impl true
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [out: :string])
    dir = opts[:out] || Mix.raise("--out DIR is required")
    key_path = Path.join(dir, "offline.key")
    if File.exists?(key_path), do: Mix.raise("#{key_path} exists; refusing to overwrite")

    key = Keys.generate()
    Keys.write!(key_path, key)

    Mix.shell().info("keyid:  #{key.keyid}")
    Mix.shell().info("public: #{Base.url_encode64(key.public, padding: false)}")

    Mix.shell().info(
      "Keep offline.key off every portal host. Its public key goes into root.json " <>
        "with mix portal.precompiled.root_rotate --offline-public=<public>."
    )
  end
end
