defmodule Mix.Tasks.Portal.Precompiled.SignOffline do
  @shortdoc "Sign a bundle's offline.json with the offline key"
  @moduledoc """
  Checks the bundle in `--bundle DIR` against `--root FILE`, the CURRENT
  production `root.json` (never the bundle's own, and never an older root),
  then writes `DIR/offline.json`: the hashes of the manifests the bundle
  holds, signed by `--key`. All trust comes from `--root`: `--key` must be
  in its `offline` role and the batch must verify under its `batch` role.
  The bundle's `root.json` must be `--root` or a newer root that follows it,
  as a consistency check only. See `PRECOMPILED_API.md`, "Offline bundles".

  The batch must have been issued within the last day by the signer's
  clock, and an existing `offline.json` is never overwritten. Nothing is
  signed that `Portal.Precompiled.Offline.check_bundle/2` did not verify.
  Run it on the offline key holder's machine, never on a portal host.

      mix portal.precompiled.sign_offline --bundle DIR --key FILE --root FILE
  """
  use Mix.Task
  alias Portal.Precompiled.{Envelope, Keys, Offline}

  @max_batch_age 24 * 60 * 60

  @impl true
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args, strict: [bundle: :string, key: :string, root: :string])

    dir = required!(opts, :bundle, "--bundle DIR is required")
    key = read_key!(required!(opts, :key, "--key FILE is required"))

    trusted =
      read_trusted!(required!(opts, :root, "--root FILE is required: the trusted root.json"))

    out = Path.join(dir, "offline.json")
    refuse_existing!(out)
    %{batch: batch, root: root} = ok!(Offline.check_bundle(dir, trusted), "")
    check_signer!(root, key)
    check_fresh!(batch)
    warn_expired(root)

    sequence = System.os_time(:second)
    Mix.shell().info("signing offline.json sequence #{sequence}, batch issued #{batch["issued"]}")
    payload = Offline.payload(batch, sequence, DateTime.utc_now())
    env = Envelope.sign(payload, [{key.keyid, key.private}])
    ok!(Offline.verify(env, root), "; nothing written")

    File.write!(out, JSON.encode!(env))
    count = map_size(batch["manifests"]) + map_size(batch["manifests_v2"])
    Mix.shell().info("offline.json sequence #{sequence}, #{count} manifests")
  end

  defp required!(opts, name, message), do: opts[name] || Mix.raise(message)

  # lstat, so a link at the path counts as taken even when it dangles.
  defp refuse_existing!(path) do
    if match?({:ok, _}, File.lstat(path)),
      do: Mix.raise("#{path} exists; refusing to overwrite")
  end

  # An offline document never expires, so it is only signed over a batch
  # this signer's clock sees as at most a day old: never over an old batch
  # that later ones may since have withdrawn builds from.
  defp check_fresh!(%{"issued" => issued}) when is_binary(issued) do
    case DateTime.from_iso8601(issued) do
      {:ok, dt, _} ->
        if DateTime.diff(DateTime.utc_now(), dt, :second) > @max_batch_age,
          do: Mix.raise("batch.json was issued more than a day ago (#{issued}); refusing to sign")

      _ ->
        Mix.raise("batch.json has no valid issued time")
    end
  end

  defp check_fresh!(_), do: Mix.raise("batch.json has no valid issued time")

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
  # expired --root usually means it is not the current production root.
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
