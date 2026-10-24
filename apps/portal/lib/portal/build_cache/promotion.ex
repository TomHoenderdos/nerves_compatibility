defmodule Portal.BuildCache.Promotion do
  @moduledoc """
  Moves dependency build cache candidates a finished build reported into the
  shared build cache. This is the cache's only writer.

  ## Why the host does this

  A build container runs untrusted package code. If it could write the shared
  cache it could plant compiled beams under the key of a popular dependency,
  and every later build restoring that key would run them. So the container
  sees `/build-cache` read-only (`Portal.Builder`), writes what it compiled
  for the package under test to `/out/build-cache/<key>`, and lists those
  entries in `result.json` under `cache.candidates`. After the container has
  exited, this module decides which of them to keep. Everything in a
  candidate came from the container and is treated as hostile.

  ## Checks, in order, per candidate

    1. Only the package under test, at exactly the version under test: the
       candidate's `dep` must equal the package and the first field of its
       `dep_lock` the version. Anything else is skipped, not counted.
    2. The key is recomputed with `Compatibility.BuildCacheKey.key/1`, with
       the dependency name forced to the package under test. Every input must
       be a single-line string and `closure` a list of `%{"name", "lock"}`
       string maps; anything else refuses the candidate.
    3. The reported key must equal the recomputed one. A build cannot land a
       candidate in another package's slot without a SHA-256 preimage. From
       here on only the recomputed key is used to build paths.
    4. The lock's outer checksum must equal the one Hex.pm publishes for the
       release, which ties the candidate to the tarball Hex serves. Hex being
       unreachable promotes nothing but refuses nothing either: that is not
       the build's fault. Hex is asked at most once per call.
    5. The candidate tree must be a real directory (as must `out/build-cache`
       above it), on the same device as `out/`, holding only directories,
       regular files with a link count of 1, and Mix's own links (below).
       The tree is walked with `File.lstat/1` only, so nothing a link points
       at is ever followed. The container has exited by now, so nothing can
       change the tree between the walk and the rename.
    6. An existing entry is never replaced. The tree is renamed into a
       `<dest>.tmp.<hex>` staging name (copied with `cp -a` when the cache is
       on another filesystem), then renamed into place. `Portal.Workers.Sweep`
       prunes leftover staging names.

  ## Symlinks

  A flat ban on symlinks would refuse most of the cache: production entries
  carry Mix's own links (66 in one slug on the main builder), each of the
  form `<entry>/priv -> ../../../../deps/jose/priv` or
  `<entry>/include -> ../../../../deps_bbb/backpex/include`. So a link is
  allowed only at the top level of the tree, only named `priv` or `include`,
  and only pointing at `../../../../deps[_<target>]/<package>/<same name>`.
  Every other link refuses the candidate.

  ## Failure

  A refusal, a Hex outage or a filesystem error promotes nothing and never
  fails the build: the cache is an optimisation. `promote/6` returns counts
  for the caller to log.
  """

  require Logger

  alias Compatibility.BuildCacheKey

  @type counts :: %{promoted: non_neg_integer(), refused: non_neg_integer()}

  @string_fields ~w(elixir otp target dep_lock)

  @doc """
  Promote the candidates in `result` from `out_dir` into `cache_dir`.

  `out_dir` is the run's `out/`, `cache_dir` the per-image slug directory
  under the build cache root, or `nil` when the cache is off.
  `opts[:release_checksum]` is the Hex lookup; without it the
  `config :portal, Portal.BuildCache.Promotion, release_checksum: fun` value
  is used, then `Portal.HexPm.release_checksum/2`.
  """
  @spec promote(map(), Path.t(), Path.t() | nil, String.t(), String.t(), keyword()) :: counts()
  def promote(result, out_dir, cache_dir, package, version, opts \\ [])

  def promote(_result, _out_dir, nil, _package, _version, _opts), do: zero()

  def promote(
        %{"cache" => %{"candidates" => [_ | _] = candidates}},
        out_dir,
        cache_dir,
        package,
        version,
        opts
      )
      when is_binary(out_dir) and is_binary(cache_dir) and is_binary(package) and
             is_binary(version) do
    lookup = Keyword.get_lazy(opts, :release_checksum, &default_lookup/0)
    ctx = %{out: out_dir, cache: cache_dir, package: package, version: version, lookup: lookup}

    {counts, _hex} =
      Enum.reduce(candidates, {zero(), :unasked}, fn candidate, {counts, hex} ->
        {outcome, hex} = consider(candidate, hex, ctx)
        {count(counts, outcome), hex}
      end)

    counts
  end

  def promote(_result, _out_dir, _cache_dir, _package, _version, _opts), do: zero()

  defp zero, do: %{promoted: 0, refused: 0}

  defp count(counts, :promoted), do: Map.update!(counts, :promoted, &(&1 + 1))
  defp count(counts, :refused), do: Map.update!(counts, :refused, &(&1 + 1))
  defp count(counts, :skipped), do: counts

  defp default_lookup do
    :portal
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:release_checksum, &Portal.HexPm.release_checksum/2)
  end

  defp consider(c, hex, ctx) do
    if own?(c, ctx) do
      check_key(c, hex, ctx)
    else
      {:skipped, hex}
    end
  end

  # Step 1.
  defp own?(%{"dep" => dep, "dep_lock" => lock}, %{package: package, version: version})
       when is_binary(lock) do
    dep == package and hd(String.split(lock, " ")) == version
  end

  defp own?(_c, _ctx), do: false

  # Steps 2 and 3.
  defp check_key(c, hex, ctx) do
    reported = c["key"]

    case recompute(c, ctx.package) do
      {:ok, ^reported = key} ->
        check_checksum(c, key, hex, ctx)

      {:ok, key} ->
        Logger.warning(
          "Build cache candidate for #{ctx.package} #{ctx.version} reported key " <>
            "#{inspect(reported, printable_limit: 80)} but its inputs hash to #{key}; refused"
        )

        {:refused, hex}

      :error ->
        Logger.warning(
          "Build cache candidate for #{ctx.package} #{ctx.version} has malformed inputs; refused"
        )

        {:refused, hex}
    end
  end

  defp recompute(c, package) do
    with true <- Enum.all?(@string_fields, &is_binary(c[&1])),
         {:ok, closure} <- closure(c["closure"]) do
      BuildCacheKey.key(%{
        elixir: c["elixir"],
        otp: c["otp"],
        target: c["target"],
        dep: package,
        dep_lock: c["dep_lock"],
        closure: closure
      })
    else
      _ -> :error
    end
  end

  # `BuildCacheKey.key/1` turns each entry into a tuple and would raise on
  # anything else, so the shape is checked here first.
  defp closure(entries) when is_list(entries) do
    if Enum.all?(entries, &closure_entry?/1),
      do: {:ok, Enum.map(entries, &{&1["name"], &1["lock"]})},
      else: :error
  end

  defp closure(_entries), do: :error

  defp closure_entry?(%{"name" => name, "lock" => lock}), do: is_binary(name) and is_binary(lock)
  defp closure_entry?(_entry), do: false

  # Step 4.
  defp check_checksum(c, key, hex, ctx) do
    case String.split(c["dep_lock"], " ") do
      [_version, _inner, outer] when outer != "" ->
        hex = ask_hex(hex, ctx)

        case hex do
          {:ok, ^outer} ->
            {check_tree_and_move(c, key, ctx), hex}

          {:ok, _other} ->
            Logger.warning(
              "Build cache candidate for #{ctx.package} #{ctx.version} carries an outer " <>
                "checksum Hex.pm does not publish for the release; refused"
            )

            {:refused, hex}

          other ->
            Logger.info(
              "Build cache candidate for #{ctx.package} #{ctx.version} not promoted: " <>
                "Hex.pm checksum lookup returned #{inspect(other)}"
            )

            {:skipped, hex}
        end

      _ ->
        Logger.warning(
          "Build cache candidate for #{ctx.package} #{ctx.version} has no outer checksum; refused"
        )

        {:refused, hex}
    end
  end

  defp ask_hex(:unasked, ctx), do: ctx.lookup.(ctx.package, ctx.version)
  defp ask_hex(answer, _ctx), do: answer

  # Steps 5 and 6.
  defp check_tree_and_move(c, key, ctx) do
    case check_tree(key, ctx) do
      :ok ->
        move(c, key, ctx)

      {:error, reason} ->
        Logger.warning(
          "Build cache candidate #{key} for #{ctx.package} #{ctx.version} refused: #{reason}"
        )

        :refused
    end
  end

  # `out` is the run's scratch output dir (operator config + run id); `key`
  # is a 64-hex string this module computed, never the container's.
  # sobelow_skip ["Traversal.FileModule"]
  defp check_tree(key, ctx) do
    parent = Path.join(ctx.out, "build-cache")
    source = Path.join(parent, key)

    with {:ok, %File.Stat{} = out} <- lstat(ctx.out),
         {:ok, %File.Stat{type: :directory}} <- lstat(parent),
         {:ok, %File.Stat{type: :directory} = src} <- lstat(source),
         true <- same_device?(out, src) || {:error, "not on the output directory's device"} do
      walk(source, true, ctx.package)
    else
      {:ok, %File.Stat{type: type}} -> {:error, "not a directory (#{type})"}
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, "cannot stat: #{inspect(reason)}"}
    end
  end

  defp same_device?(a, b),
    do: a.major_device == b.major_device and a.minor_device == b.minor_device

  # Paths below the candidate root, named by `File.ls/1` of a directory
  # `lstat` showed is real.
  # sobelow_skip ["Traversal.FileModule"]
  defp walk(dir, top?, package) do
    case File.ls(dir) do
      {:ok, names} ->
        Enum.reduce_while(names, :ok, fn name, :ok ->
          dir |> Path.join(name) |> check_entry(name, top?, package) |> continue_if_ok()
        end)

      {:error, reason} ->
        {:error, "cannot list #{dir}: #{inspect(reason)}"}
    end
  end

  defp continue_if_ok(:ok), do: {:cont, :ok}
  defp continue_if_ok(error), do: {:halt, error}

  defp check_entry(path, name, top?, package) do
    case lstat(path) do
      {:ok, %File.Stat{type: :directory}} -> walk(path, false, package)
      {:ok, %File.Stat{type: :regular, links: 1}} -> :ok
      {:ok, %File.Stat{type: :regular}} -> {:error, "hardlinked file #{path}"}
      {:ok, %File.Stat{type: :symlink}} -> check_link(path, name, top?, package)
      {:ok, %File.Stat{type: type}} -> {:error, "#{type} at #{path}"}
      {:error, reason} -> {:error, "cannot stat #{path}: #{inspect(reason)}"}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp check_link(path, name, true, package) when name in ["priv", "include"] do
    allowed =
      ~r/\A\.\.\/\.\.\/\.\.\/\.\.\/deps(_[a-z0-9_]+)?\/#{Regex.escape(package)}\/(priv|include)\z/

    with {:ok, target} <- File.read_link(path),
         [_, _deps, ^name] <- Regex.run(allowed, target) do
      :ok
    else
      _ -> {:error, "symlink #{path} is not Mix's own #{name} link"}
    end
  end

  defp check_link(path, _name, _top?, _package), do: {:error, "symlink #{path}"}

  # `cache` is the per-image slug dir under the operator's cache root; `key`
  # is the host-computed 64-hex key; the staging suffix is host random.
  # sobelow_skip ["Traversal.FileModule"]
  defp move(c, key, ctx) do
    source = Path.join([ctx.out, "build-cache", key])
    dest = Path.join(ctx.cache, key)

    case lstat(dest) do
      {:ok, _exists} ->
        :skipped

      {:error, _} ->
        staging = dest <> ".tmp." <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

        with :ok <- File.mkdir_p(ctx.cache),
             :ok <- stage(source, staging),
             :ok <- File.rename(staging, dest) do
          Logger.info(
            "Promoted build cache entry #{key} for #{ctx.package} #{ctx.version} (#{c["target"]})"
          )

          :promoted
        else
          error ->
            _ = File.rm_rf(staging)

            Logger.warning(
              "Could not promote build cache entry #{key} for #{ctx.package} " <>
                "#{ctx.version}: #{inspect(error)}"
            )

            :skipped
        end
    end
  end

  # Both paths come from `move/3`; `cp` gets them as arguments, no shell.
  # sobelow_skip ["Traversal.FileModule", "CI.System"]
  defp stage(source, staging) do
    case File.rename(source, staging) do
      :ok ->
        :ok

      {:error, :exdev} ->
        with :ok <- File.mkdir_p(staging),
             {_out, 0} <-
               System.cmd("cp", ["-a", source <> "/.", staging], stderr_to_stdout: true) do
          :ok
        else
          {out, status} when is_integer(status) -> {:error, {:cp, status, out}}
          error -> error
        end

      error ->
        error
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp lstat(path), do: File.lstat(path)
end
