defmodule Portal.Precompiled.Offline do
  @moduledoc """
  The offline document of a bundle (`PRECOMPILED_API.md`, "Offline bundles"):
  the manifest hashes of the manifests a bundle holds, re-signed by the
  root's `offline` role, with no expiry, so a device that never reconnects
  can keep installing from it. Signed on the offline key holder's machine,
  never on a portal host.

  `check_bundle/2` is the signer's check and never trusts the bundle on its
  own: the bundle's `root.json` must be the trusted root the operator names,
  or follow it by the chain rule (`Portal.Precompiled.Root.follows/2`). The
  batch must verify under that root, and every manifest the bundle holds
  must hash to the batch's entry. Only those manifests are signed.
  """
  alias Portal.Precompiled.{Envelope, Root}

  # A Hex package name; anything else in a batch is never turned into a path.
  @package ~r/\A[a-z][a-z0-9_]*\z/
  @sha ~r/\A[0-9a-f]{64}\z/
  @maps [
    {"manifests", ["manifests"], "format-1 manifest"},
    {"manifests_v2", ["v2", "manifests"], "manifest"}
  ]

  @spec payload(map(), pos_integer(), DateTime.t()) :: binary()
  def payload(batch, sequence, %DateTime{} = issued)
      when is_integer(sequence) and sequence > 0 do
    JSON.encode!(%{
      "version" => 1,
      "kind" => "offline",
      "sequence" => sequence,
      "issued" => DateTime.to_iso8601(issued),
      "manifests" => Map.get(batch, "manifests") || %{},
      "manifests_v2" => Map.get(batch, "manifests_v2") || %{}
    })
  end

  @doc """
  Checks the bundle in `dir` against `trusted`, the bytes of a root envelope
  the operator trusts (the production `root.json`). Returns the batch payload
  narrowed to the manifests the bundle holds, and the root in use: `trusted`,
  or the bundle's newer root when it follows `trusted`. Expiry plays no part:
  neither the root's nor the batch's.
  """
  @spec check_bundle(Path.t(), binary()) ::
          {:ok, %{batch: map(), root: map()}} | {:error, String.t()}
  def check_bundle(dir, trusted) when is_binary(trusted) do
    with {:ok, trusted_root, trusted_bytes} <- trusted_root(trusted),
         {:ok, root} <- bundle_root(dir, trusted_root, trusted_bytes),
         {:ok, batch} <- verified_batch(dir, root),
         {:ok, scoped} <- scope(dir, batch) do
      {:ok, %{batch: scoped, root: root}}
    end
  end

  @doc """
  Verifies an `offline.json` envelope under `root`'s `offline` role and
  returns its payload. No clock is read: the document has no expiry, and the
  root's expiry does not bound it.
  """
  @spec verify(map() | binary(), map()) :: {:ok, map()} | {:error, String.t()}
  def verify(env, root) do
    with {:role, {:ok, {keys, t}}} <- {:role, Root.role_keys(root, "offline")},
         {:sig, {:ok, bytes}} <- {:sig, Envelope.verify(env, keys, t)},
         {:ok, %{"kind" => "offline"} = doc} <- JSON.decode(bytes) do
      {:ok, doc}
    else
      {:role, _} -> {:error, "the root has no offline role"}
      {:sig, _} -> {:error, "offline.json does not verify under the root's offline role"}
      _ -> {:error, "offline.json is not an offline document"}
    end
  end

  defp trusted_root(bytes) do
    case Root.verify_self(bytes) do
      {:ok, root, payload} -> {:ok, root, payload}
      :error -> {:error, "the trusted root does not verify under itself"}
    end
  end

  defp bundle_root(dir, trusted, trusted_bytes) do
    case read_json(dir, ["root.json"]) do
      {:ok, env} -> chain(env, trusted, trusted_bytes)
      :error -> {:error, "bundle root.json is missing or not an envelope"}
    end
  end

  # The trusted root itself (the same payload bytes), or a newer one that
  # follows it. Same version with other bytes is a fork and does not chain.
  defp chain(env, trusted, trusted_bytes) do
    case Root.verify_self(env) do
      {:ok, _, ^trusted_bytes} -> {:ok, trusted}
      {:ok, root, _} -> newer_root(env, root, trusted)
      :error -> {:error, "bundle root.json does not chain from the trusted root"}
    end
  end

  defp newer_root(_env, %{"version" => v}, %{"version" => tv})
       when is_integer(v) and is_integer(tv) and v < tv,
       do: {:error, "bundle root.json version #{v} is older than the trusted root (#{tv})"}

  defp newer_root(env, _root, trusted) do
    case Root.follows(env, trusted) do
      {:ok, root, _} -> {:ok, root}
      :error -> {:error, "bundle root.json does not chain from the trusted root"}
    end
  end

  defp verified_batch(dir, root) do
    with {:ok, env} <- read_json(dir, ["batch.json"]),
         {:ok, {keys, t}} <- Root.role_keys(root, "batch"),
         {:ok, bytes} <- Envelope.verify(env, keys, t),
         {:ok, %{} = batch} <- JSON.decode(bytes) do
      {:ok, batch}
    else
      _ -> {:error, "batch.json does not verify under the root in use"}
    end
  end

  # Keeps the entries whose manifest the bundle holds and whose bytes hash to
  # the entry. A bundle need not hold every manifest the batch names, only
  # those its install needs; a held one that does not match refuses the bundle.
  defp scope(dir, batch) do
    result =
      Enum.reduce_while(@maps, {:ok, batch}, fn {key, subdir, label}, {:ok, acc} ->
        case held(dir, subdir, label, entries(batch, key)) do
          {:ok, kept} -> {:cont, {:ok, Map.put(acc, key, kept)}}
          error -> {:halt, error}
        end
      end)

    case result do
      {:ok, %{"manifests" => m1, "manifests_v2" => m2}} when m1 == %{} and m2 == %{} ->
        {:error, "the bundle holds none of the batch's manifests"}

      other ->
        other
    end
  end

  defp entries(batch, key) do
    case Map.get(batch, key) do
      %{} = map -> Enum.filter(map, &plain_entry?/1)
      _ -> []
    end
  end

  defp plain_entry?({name, sha}),
    do: is_binary(name) and is_binary(sha) and name =~ @package and sha =~ @sha

  defp held(dir, subdir, label, entries) do
    Enum.reduce_while(entries, {:ok, %{}}, fn {name, sha}, {:ok, acc} ->
      case read(dir, subdir ++ [name <> ".json"]) do
        {:ok, bytes} -> keep(acc, name, sha, sha256(bytes) == sha, label)
        {:error, _} -> {:cont, {:ok, acc}}
      end
    end)
  end

  defp keep(acc, name, sha, true, _label), do: {:cont, {:ok, Map.put(acc, name, sha)}}

  defp keep(_acc, name, _sha, false, label),
    do: {:halt, {:error, "#{label} #{name} does not match the batch"}}

  defp read_json(dir, parts) do
    with {:ok, body} <- read(dir, parts),
         {:ok, %{} = map} <- JSON.decode(body) do
      {:ok, map}
    else
      _ -> :error
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  # The bundle dir is the operator's command-line argument, and the names
  # joined to it are fixed or a package name checked against @package.
  defp read(dir, parts), do: File.read(Path.join([dir | parts]))

  defp sha256(b), do: Base.encode16(:crypto.hash(:sha256, b), case: :lower)
end
