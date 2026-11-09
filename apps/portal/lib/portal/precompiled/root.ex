defmodule Portal.Precompiled.Root do
  @moduledoc "The root document: which keys may sign batches and roots, and the thresholds."
  alias Portal.Precompiled.{Envelope, Keys}

  @type role :: {[String.t()], pos_integer()}

  @spec payload(String.t(), binary(), DateTime.t()) :: binary()
  def payload(keyid, public, %DateTime{} = expires) do
    payload(%{
      version: 1,
      expires: expires,
      keys: [{keyid, public}],
      roles: %{"root" => {[keyid], 1}, "batch" => {[keyid], 1}}
    })
  end

  @doc """
  A root document over any key set and roles: `root` and `batch` always,
  `offline` when bundles may be signed by their own key (`PRECOMPILED_API.md`,
  "Offline bundles").
  """
  @spec payload(%{
          version: pos_integer(),
          expires: DateTime.t(),
          keys: [{String.t(), binary()}],
          roles: %{String.t() => role()}
        }) :: binary()
  def payload(%{version: v, expires: %DateTime{} = exp, keys: keys, roles: roles})
      when is_integer(v) and v > 0 do
    JSON.encode!(%{
      "version" => v,
      "expires" => DateTime.to_iso8601(exp),
      "keys" =>
        Map.new(keys, fn {id, pub} ->
          {id, %{"type" => "ed25519", "public" => Base.url_encode64(pub, padding: false)}}
        end),
      "roles" =>
        Map.new(roles, fn {name, {ids, t}} -> {name, %{"keyids" => ids, "threshold" => t}} end)
    })
  end

  @doc """
  The keys and threshold a decoded root names for `role`, with each public
  key decoded. `:error` when the role is absent or malformed. Keys the role
  names but the root does not list are left out, so they never count.
  """
  @spec role_keys(map(), String.t()) :: {:ok, {%{String.t() => binary()}, pos_integer()}} | :error
  def role_keys(root, role) do
    case root do
      %{"roles" => %{^role => %{"keyids" => ids, "threshold" => t}}}
      when is_list(ids) and is_integer(t) and t > 0 ->
        {:ok, {resolve(root, ids), t}}

      _ ->
        :error
    end
  end

  defp resolve(root, ids) do
    for id <- ids,
        is_binary(id),
        %{"public" => pub} <- [get_in(root, ["keys", id])],
        is_binary(pub),
        {:ok, raw} <- [Base.url_decode64(pub, padding: false)],
        byte_size(raw) == 32,
        into: %{},
        do: {id, raw}
  end

  @doc """
  A root envelope (a map, or its JSON bytes) that verifies under its own
  `root` role: `{:ok, root, payload_bytes}`. The role's keys are read from
  the unverified payload; the signature check then decides.
  """
  @spec verify_self(map() | binary()) :: {:ok, map(), binary()} | :error
  def verify_self(env) when is_binary(env) do
    case JSON.decode(env) do
      {:ok, map} when is_map(map) -> verify_self(map)
      _ -> :error
    end
  end

  def verify_self(%{"payload" => p} = env) when is_binary(p) do
    with {:ok, bytes} <- Base.url_decode64(p, padding: false),
         {:ok, %{} = root} <- JSON.decode(bytes),
         {:ok, {keys, t}} <- role_keys(root, "root"),
         {:ok, ^bytes} <- Envelope.verify(env, keys, t) do
      {:ok, root, bytes}
    else
      _ -> :error
    end
  end

  def verify_self(_), do: :error

  @doc """
  Whether the root envelope `env` may follow `current`, by the client's chain
  rule: it verifies under its own root role and under `current`'s, and its
  version is higher. Expiry is not part of the chain (see `PRECOMPILED_API.md`,
  "Offline bundles").
  """
  @spec follows(map() | binary(), map()) :: {:ok, map(), binary()} | :error
  def follows(env, %{"version" => cv} = current) when is_integer(cv) do
    with {:ok, %{"version" => v} = root, bytes} when is_integer(v) and v > cv <- verify_self(env),
         {:ok, {keys, t}} <- role_keys(current, "root"),
         {:ok, ^bytes} <- Envelope.verify(env, keys, t) do
      {:ok, root, bytes}
    else
      _ -> :error
    end
  end

  def follows(_, _), do: :error

  @doc "The signed root envelope bytes next to the signing key, as served."
  @spec load() :: {:ok, binary()} | {:error, :no_root}
  # sobelow_skip ["Traversal.FileModule"]
  # Path comes from Keys.root_path, derived from PRECOMPILED_SIGNING_KEY config, not a request.
  def load do
    with path when is_binary(path) <- Keys.root_path(),
         {:ok, body} <- File.read(path) do
      {:ok, body}
    else
      _ -> {:error, :no_root}
    end
  end
end
