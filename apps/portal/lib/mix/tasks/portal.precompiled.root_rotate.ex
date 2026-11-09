defmodule Mix.Tasks.Portal.Precompiled.RootRotate do
  @shortdoc "Sign the next root.json, delegating the offline role to a key"
  @moduledoc """
  Reads the current signed root (`--root FILE`), keeps its keys and its
  `root` and `batch` roles, names the offline key in the `offline` role
  (`--offline-public-file PATH`, the `offline.pub` that
  `mix portal.precompiled.offline_keygen` writes, or `--offline-public=B64`),
  and writes the next version, signed by `--key`, to `--out FILE`.

  `--key` must be a key of the current root's `root` role, so the new root
  follows the current one by the client's chain rule. The `offline` role is
  delegated by the root role, never by the batch role. Rotating again
  replaces the offline key: the previous one leaves `keys` unless another
  role still names it. The offline key must be a key of its own, not one the
  root already names. `--years N` sets the expiry (default 1); an offline
  document does not depend on it (`PRECOMPILED_API.md`, "Offline bundles").

      mix portal.precompiled.root_rotate --root FILE --key FILE \\
        --offline-public-file PATH --out FILE [--years N]

  Give `--offline-public` in the `--offline-public=B64` form: a base64url key
  may start with `-`, which the separate-argument form would read as a
  switch. Refuses to overwrite `--out`.
  """
  use Mix.Task
  alias Portal.Precompiled.{Envelope, Keys, Root}

  @max_public_file 4096

  @switches [
    root: :string,
    key: :string,
    offline_public: :string,
    offline_public_file: :string,
    out: :string,
    years: :integer
  ]

  @impl true
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: @switches)
    root_path = required!(opts, :root, "--root FILE is required")
    key_path = required!(opts, :key, "--key FILE is required")
    public_b64 = offline_public!(opts)
    out = required!(opts, :out, "--out FILE is required")
    # lstat, so a link at --out counts as taken even when it dangles.
    if match?({:ok, _}, File.lstat(out)), do: Mix.raise("#{out} exists; refusing to overwrite")

    current = read_root!(root_path)
    key = read_key!(key_path)
    check_signer!(current, key)
    offline_public = decode_public!(public_b64)
    offline_id = Keys.keyid(offline_public)
    check_own_key!(current, offline_id)

    payload =
      Root.payload(%{
        version: current["version"] + 1,
        expires: DateTime.add(DateTime.utc_now(), 365 * (opts[:years] || 1), :day),
        keys: next_keys(current) ++ [{offline_id, offline_public}],
        roles: Map.put(roles(current), "offline", {[offline_id], 1})
      })

    env = Envelope.sign(payload, [{key.keyid, key.private}])

    check_follows!(env, current, root_path)

    File.write!(out, JSON.encode!(env))
    Mix.shell().info("root version #{current["version"] + 1}, offline keyid #{offline_id}")
    Mix.shell().info("wrote #{out}")
  end

  defp required!(opts, name, message), do: opts[name] || Mix.raise(message)

  defp offline_public!(opts) do
    case {opts[:offline_public], opts[:offline_public_file]} do
      {b64, nil} when is_binary(b64) -> b64
      {nil, path} when is_binary(path) -> read_public_file!(path)
      _ -> Mix.raise("give exactly one of --offline-public=B64 and --offline-public-file PATH")
    end
  end

  # A regular file (lstat, so never through a link) of at most 4 KiB.
  defp read_public_file!(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_public_file ->
        path |> File.read!() |> String.trim()

      {:ok, %File.Stat{type: :regular}} ->
        Mix.raise("#{path} is larger than #{@max_public_file} bytes")

      {:ok, _} ->
        Mix.raise("#{path} is not a regular file")

      {:error, reason} ->
        Mix.raise("cannot read #{path}: #{:file.format_error(reason)}")
    end
  end

  defp check_own_key!(current, offline_id) do
    if Map.has_key?(current["keys"], offline_id),
      do:
        Mix.raise(
          "the offline key must be its own key; the current root already names #{offline_id}"
        )

    :ok
  end

  defp check_follows!(env, current, root_path) do
    case Root.follows(env, current) do
      {:ok, _, _} -> :ok
      :error -> Mix.raise("the signed root does not follow #{root_path}; nothing written")
    end
  end

  defp read_root!(path) do
    with {:ok, body} <- File.read(path),
         {:ok, %{"version" => v, "keys" => %{}} = root, _} when is_integer(v) <-
           Root.verify_self(body) do
      root
    else
      _ -> Mix.raise("#{path} does not verify under itself")
    end
  end

  defp read_key!(path) do
    case Keys.read(path) do
      {:ok, key} -> key
      {:error, _} -> Mix.raise("#{path} is not a readable Ed25519 key file")
    end
  end

  defp check_signer!(current, key) do
    %{"keyids" => ids, "threshold" => t} = current["roles"]["root"]

    unless key.keyid in ids,
      do: Mix.raise("#{key.keyid} is not a root key of the current root")

    if t > 1,
      do: Mix.raise("the current root role needs #{t} signatures; this task signs with one key")

    :ok
  end

  defp decode_public!(b64) do
    case Base.url_decode64(b64, padding: false) do
      {:ok, raw} when byte_size(raw) == 32 -> raw
      _ -> Mix.raise("--offline-public must be a 32-byte base64url Ed25519 public key")
    end
  end

  # Every key some role other than `offline` still names; the previous
  # offline key goes with its role.
  defp next_keys(current) do
    kept =
      current["roles"]
      |> Map.delete("offline")
      |> Enum.flat_map(fn {_, %{"keyids" => ids}} -> ids end)
      |> MapSet.new()

    for {id, %{"public" => pub}} <- current["keys"], id in kept do
      case Base.url_decode64(pub, padding: false) do
        {:ok, raw} when byte_size(raw) == 32 -> {id, raw}
        _ -> Mix.raise("key #{id} of the current root is not a 32-byte public key")
      end
    end
  end

  defp roles(current) do
    Map.new(current["roles"], fn
      {name, %{"keyids" => ids, "threshold" => t}} when is_list(ids) and is_integer(t) ->
        {name, {ids, t}}

      {name, _} ->
        Mix.raise("role #{name} of the current root is malformed")
    end)
  end
end
