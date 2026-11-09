defmodule Mix.Tasks.Portal.Precompiled.OfflineKeygen do
  @shortdoc "Generate the key of the precompiled offline signing role"
  @moduledoc """
  Writes `offline.key` (mode 0600; a directory it creates is 0700) and
  `offline.pub` (the base64url public key) into `--out DIR`, and prints the
  keyid and public key. The key signs bundles' `offline.json`
  (`PRECOMPILED_API.md`, "Offline bundles") once a root names it in its
  `offline` role (`mix portal.precompiled.root_rotate`). Keep it off every
  portal host. Refuses to overwrite either file.

      mix portal.precompiled.offline_keygen --out DIR
  """
  use Mix.Task
  alias Portal.Precompiled.Keys

  @impl true
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [out: :string])
    dir = opts[:out] || Mix.raise("--out DIR is required")
    key_path = Path.join(dir, "offline.key")
    pub_path = Path.join(dir, "offline.pub")
    refuse_existing!(key_path)
    refuse_existing!(pub_path)

    key = Keys.generate()
    public = Base.url_encode64(key.public, padding: false)
    Keys.write!(key_path, key)
    File.write!(pub_path, public <> "\n")

    Mix.shell().info("keyid:  #{key.keyid}")
    Mix.shell().info("public: #{public}")

    Mix.shell().info(
      "Keep offline.key off every portal host. Its public key goes into root.json " <>
        "with mix portal.precompiled.root_rotate --offline-public-file #{pub_path}."
    )
  end

  # lstat, so a link at the path counts as taken even when it dangles.
  defp refuse_existing!(path) do
    if match?({:ok, _}, File.lstat(path)),
      do: Mix.raise("#{path} exists; refusing to overwrite")
  end
end
