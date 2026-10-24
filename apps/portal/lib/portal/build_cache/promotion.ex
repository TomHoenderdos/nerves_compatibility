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

  ## How many

  A run builds the host compile and each system once, so it can have at most
  one candidate per entry in `result["systems"]` plus one. Candidates past
  that are ignored, neither promoted nor refused, and logged once as a count:
  without the cap a build could list thousands of trees, each passing every
  check below on its own, and fill the cache disk.

  ## Checks, in order, per candidate

    1. Only the package under test, at exactly the version under test: the
       candidate's `dep` must equal the package and the first field of its
       `dep_lock` the version. Anything else is skipped, not counted.
    2. Only what the run built, by the toolchain it built with: `target` must
       be `"host"`, `"any"` or the mix target of a system in
       `result["systems"]`, and `elixir` and `otp` must equal the run's
       `toolchain.elixir` and `toolchain.erlang`. A run with no toolchain
       refuses every candidate.
    3. The key is recomputed with `Compatibility.BuildCacheKey.key/1`, with
       the dependency name forced to the package under test. Every input must
       be a single-line string and `closure` a list of `%{"name", "lock"}`
       string maps; anything else refuses the candidate.
    4. The reported key must equal the recomputed one. A build cannot land a
       candidate in another package's slot without a SHA-256 preimage. From
       here on only the recomputed key is used to build paths. Refusals here
       are logged once per call, as a count with one example.
    5. The lock's outer checksum must equal the one Hex.pm publishes for the
       release, which ties the candidate to the tarball Hex serves. Hex being
       unreachable promotes nothing but refuses nothing either: that is not
       the build's fault. Hex is asked at most once per call.
    6. The candidate tree must be a real directory (as must `out/build-cache`
       above it), on the same device as `out/`, holding only directories,
       regular files with a link count of 1, and Mix's own links (below).
       The tree is walked with `File.lstat/1` only, so nothing a link points
       at is ever followed, and listed with `:file.list_dir_all/1`, because
       `File.ls/1` silently drops names that are not valid UTF-8 on Linux
       and such an entry would be promoted unchecked. Any such name refuses
       the candidate: every real Mix artifact name is UTF-8.
       The container has exited by now. A concurrent build could still hold
       a file descriptor into the tree, passed through the read-write caches
       builds share, and change it between the walk and the rename; what it
       can reach that way is limited to its own package's slot, which step 4
       already pins.
    7. An existing entry is never replaced. The tree is renamed into a
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

  @type counts :: %{
          promoted: non_neg_integer(),
          refused: non_neg_integer(),
          ignored: non_neg_integer()
        }

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
        %{"cache" => %{"candidates" => [_ | _] = candidates}} = result,
        out_dir,
        cache_dir,
        package,
        version,
        opts
      )
      when is_binary(out_dir) and is_binary(cache_dir) and is_binary(package) and
             is_binary(version) do
    lookup = Keyword.get_lazy(opts, :release_checksum, &default_lookup/0)
    systems = systems(result)
    limit = map_size(systems) + 1
    {kept, extra} = Enum.split(candidates, limit)

    ctx = %{
      out: out_dir,
      cache: cache_dir,
      package: package,
      version: version,
      lookup: lookup,
      targets: built_targets(systems),
      toolchain: toolchain(result)
    }

    {counts, _hex} =
      Enum.reduce(kept, {zero(), :unasked}, fn candidate, {counts, hex} ->
        {outcome, hex} = consider(candidate, hex, ctx)
        {count(counts, outcome), hex}
      end)

    log_ignored(length(extra), limit, ctx)
    log_mismatches(counts, ctx)

    counts
    |> Map.take([:promoted, :refused])
    |> Map.put(:ignored, length(extra))
  end

  def promote(_result, _out_dir, _cache_dir, _package, _version, _opts), do: zero()

  defp zero, do: %{promoted: 0, refused: 0, ignored: 0}

  defp count(counts, :promoted), do: Map.update!(counts, :promoted, &(&1 + 1))
  defp count(counts, :refused), do: Map.update!(counts, :refused, &(&1 + 1))
  defp count(counts, :skipped), do: counts

  # A key mismatch is a refusal whose log line is summed per call, keeping
  # the first reported key as the example.
  defp count(counts, {:mismatch, reported, key}) do
    counts
    |> count(:refused)
    |> Map.update(:mismatched, 1, &(&1 + 1))
    |> Map.put_new(:mismatch_example, {reported, key})
  end

  defp log_ignored(0, _limit, _ctx), do: :ok

  defp log_ignored(n, limit, ctx) do
    Logger.warning(
      "Ignored #{n} build cache candidate(s) over the limit of #{limit} " <>
        "for #{ctx.package} #{ctx.version}"
    )
  end

  defp log_mismatches(%{mismatched: n, mismatch_example: {reported, key}}, ctx) do
    Logger.warning(
      "Refused #{n} build cache candidate(s) for #{ctx.package} #{ctx.version} whose " <>
        "reported key is not the recomputed one; e.g. reported #{show(reported)} " <>
        "but its inputs hash to #{key}"
    )
  end

  defp log_mismatches(_counts, _ctx), do: :ok

  # `result["systems"]` is keyed by system name: `nerves_system_<target>` for
  # a firmware build, plus `"host"` (the host compile) or `"pure_elixir"`.
  defp systems(%{"systems" => systems}) when is_map(systems), do: systems
  defp systems(_result), do: %{}

  # The targets a candidate may name: the host compile, a target-independent
  # build, or the mix target of a system the run built. The name-to-target
  # rule replicates `NccWorker.Systems`, where every system's `target` is its
  # `name` without the `nerves_system_` prefix (the portal does not depend on
  # ncc_worker). `"host"` and `"pure_elixir"` keys build no mix target.
  defp built_targets(systems) do
    systems
    |> Map.keys()
    |> Enum.flat_map(fn
      "nerves_system_" <> target when target != "" -> [target]
      _other -> []
    end)
    |> Enum.concat(["host", "any"])
    |> MapSet.new()
  end

  # The worker writes `toolchain.elixir` as `System.version()` and
  # `toolchain.erlang` as `:erlang.system_info(:otp_release)`, the same two
  # calls its cache key's `elixir` and `otp` come from, so they compare as
  # strings. `nil` (no toolchain reported) refuses every candidate.
  defp toolchain(%{"toolchain" => %{"elixir" => elixir, "erlang" => otp}})
       when is_binary(elixir) and is_binary(otp),
       do: {elixir, otp}

  defp toolchain(_result), do: nil

  defp default_lookup do
    :portal
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:release_checksum, &Portal.HexPm.release_checksum/2)
  end

  defp consider(c, hex, ctx) do
    cond do
      not own?(c, ctx) -> {:skipped, hex}
      not built?(c, ctx) -> {:refused, hex}
      not same_toolchain?(c, ctx) -> {:refused, hex}
      true -> check_key(c, hex, ctx)
    end
  end

  # Step 2.
  defp built?(c, ctx) do
    MapSet.member?(ctx.targets, c["target"]) ||
      refuse_log(c, ctx, "names target #{show(c["target"])}, which the run did not build")
  end

  defp same_toolchain?(c, ctx) do
    {c["elixir"], c["otp"]} == ctx.toolchain ||
      refuse_log(
        c,
        ctx,
        "was built by Elixir #{show(c["elixir"])} OTP #{show(c["otp"])}, " <>
          "not the run's toolchain"
      )
  end

  defp refuse_log(_c, ctx, why) do
    Logger.warning("Build cache candidate for #{ctx.package} #{ctx.version} #{why}; refused")
    false
  end

  # Step 1.
  defp own?(%{"dep" => dep, "dep_lock" => lock}, %{package: package, version: version})
       when is_binary(lock) do
    dep == package and hd(String.split(lock, " ")) == version
  end

  defp own?(_c, _ctx), do: false

  # Steps 3 and 4.
  defp check_key(c, hex, ctx) do
    reported = c["key"]

    case recompute(c, ctx.package) do
      {:ok, ^reported = key} ->
        check_checksum(c, key, hex, ctx)

      {:ok, key} ->
        {{:mismatch, reported, key}, hex}

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

  # Step 5.
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

  # Steps 6 and 7.
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

    with {:ok, %File.Stat{type: :directory} = out} <- lstat(ctx.out),
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

  # Paths below the candidate root, named by a raw listing of a directory
  # `lstat` showed is real. Not `File.ls/1`: see the moduledoc, step 6.
  # sobelow_skip ["Traversal.FileModule"]
  defp walk(dir, top?, package) do
    case :file.list_dir_all(dir) do
      {:ok, names} ->
        Enum.reduce_while(names, :ok, fn raw, :ok ->
          raw |> check_name(dir, top?, package) |> continue_if_ok()
        end)

      {:error, reason} ->
        {:error, "cannot list #{show(dir)}: #{inspect(reason)}"}
    end
  end

  defp check_name(raw, dir, top?, package) do
    case name_string(raw) do
      {:ok, name} ->
        dir |> Path.join(name) |> check_entry(name, top?, package)

      :error ->
        {:error, "name that is not valid UTF-8 in #{show(dir)}: #{show(raw)}"}
    end
  end

  @doc false
  # A name as `:file.list_dir_all/1` returns it: a charlist when it decodes
  # in the native name encoding, a binary of raw bytes when it does not.
  @spec name_string(binary() | charlist()) :: {:ok, String.t()} | :error
  def name_string(name) when is_list(name) do
    case :unicode.characters_to_binary(name) do
      bin when is_binary(bin) -> name_string(bin)
      _ -> :error
    end
  rescue
    ArgumentError -> :error
  end

  def name_string(name) when is_binary(name) do
    if String.valid?(name) and name not in ["", ".", ".."] and
         not String.contains?(name, ["/", <<0>>]),
       do: {:ok, name},
       else: :error
  end

  def name_string(_name), do: :error

  # Every container-chosen string reaches the log through here: escaped, so
  # a newline cannot forge a line and invalid UTF-8 cannot make the
  # formatter drop it, and bounded.
  defp show(term), do: inspect(term, printable_limit: 200, binaries: :as_strings)

  defp continue_if_ok(:ok), do: {:cont, :ok}
  defp continue_if_ok(error), do: {:halt, error}

  defp check_entry(path, name, top?, package) do
    case lstat(path) do
      {:ok, %File.Stat{type: :directory}} -> walk(path, false, package)
      {:ok, %File.Stat{type: :regular, links: 1}} -> :ok
      {:ok, %File.Stat{type: :regular}} -> {:error, "hardlinked file #{show(path)}"}
      {:ok, %File.Stat{type: :symlink}} -> check_link(path, name, top?, package)
      {:ok, %File.Stat{type: type}} -> {:error, "#{type} at #{show(path)}"}
      {:error, reason} -> {:error, "cannot stat #{show(path)}: #{inspect(reason)}"}
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
      _ -> {:error, "symlink #{show(path)} is not Mix's own #{name} link"}
    end
  end

  defp check_link(path, _name, _top?, _package), do: {:error, "symlink #{show(path)}"}

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
            "Promoted build cache entry #{key} for #{ctx.package} #{ctx.version} " <>
              "(#{show(c["target"])})"
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
