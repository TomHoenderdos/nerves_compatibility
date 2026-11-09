defmodule Mix.Tasks.Portal.Precompiled.SignOffline do
  @shortdoc "Sign a bundle's offline.json with the offline key"
  @moduledoc """
  Checks the bundle in `--bundle DIR` against the trusted root `--root FILE`
  (the production `root.json`, never the bundle's own), then writes
  `DIR/offline.json`: the hashes of the manifests the bundle holds, signed
  by `--key`, which must be a key of the `offline` role of the root in use.
  The root in use is `--root`, or the bundle's `root.json` when it follows
  `--root` by the chain rule. See `PRECOMPILED_API.md`, "Offline bundles".

  Nothing is signed that `Portal.Precompiled.Offline.check_bundle/2` did not
  verify. Run it on the offline key holder's machine, never on a portal host.

      mix portal.precompiled.sign_offline --bundle DIR --key FILE --root FILE
  """
  use Mix.Task
  alias Portal.Precompiled.{Envelope, Keys, Offline}

  @impl true
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args, strict: [bundle: :string, key: :string, root: :string])

    dir = required!(opts, :bundle, "--bundle DIR is required")
    key = read_key!(required!(opts, :key, "--key FILE is required"))

    trusted =
      read_trusted!(required!(opts, :root, "--root FILE is required: the trusted root.json"))

    %{batch: batch, root: root} = ok!(Offline.check_bundle(dir, trusted), "")
    check_signer!(root, key)
    warn_expired(root)

    sequence = System.os_time(:second)
    payload = Offline.payload(batch, sequence, DateTime.utc_now())
    env = Envelope.sign(payload, [{key.keyid, key.private}])
    ok!(Offline.verify(env, root), "; nothing written")

    File.write!(Path.join(dir, "offline.json"), JSON.encode!(env))
    count = map_size(batch["manifests"]) + map_size(batch["manifests_v2"])
    Mix.shell().info("offline.json sequence #{sequence}, #{count} manifests")
  end

  defp required!(opts, name, message), do: opts[name] || Mix.raise(message)

  defp ok!({:ok, value}, _suffix), do: value
  defp ok!({:error, message}, suffix), do: Mix.raise(message <> suffix)

  defp read_trusted!(path) do
    case File.read(path) do
      {:ok, body} -> body
      {:error, reason} -> Mix.raise("cannot read #{path}: #{:file.format_error(reason)}")
    end
  end

  defp read_key!(path) do
    case Keys.read(path) do
      {:ok, key} -> key
      {:error, _} -> Mix.raise("#{path} is not a readable Ed25519 key file")
    end
  end

  # The offline document does not depend on the root's expiry, but an
  # expired root in use usually means --root is not the current production root.
  defp warn_expired(%{"expires" => exp, "version" => v}) when is_binary(exp) do
    with {:ok, dt, _} <- DateTime.from_iso8601(exp),
         :lt <- DateTime.compare(dt, DateTime.utc_now()) do
      Mix.shell().info(
        "note: the root in use (version #{v}) expired at #{exp}; is --root the current root?"
      )
    end

    :ok
  end

  defp warn_expired(_), do: :ok

  defp check_signer!(root, key) do
    case get_in(root, ["roles", "offline", "keyids"]) do
      ids when is_list(ids) ->
        unless key.keyid in ids,
          do: Mix.raise("#{key.keyid} is not an offline key of the root in use")

      _ ->
        Mix.raise("the root in use (version #{root["version"]}) has no offline role")
    end
  end
end
