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
    6. `out/`, `out/build-cache` and the candidate directory must be real
       directories (checked with `File.lstat/1`), the candidate on the same
       device as `out/`. Those checks are advisory: a concurrent build
       holding a file descriptor into `out/` (passed through the read-write
       caches builds share) can swap any path below it for a symlink right
       after. So the candidate is copied into a fresh `<dest>.tmp.<hex>`
       staging dir inside the cache slug by `cp -a` running in a throwaway
       container of the worker image (`copy_args/4`): no network, read-only
       root, no capabilities, the run's `out/` bound read-only at `/src` and
       the staging dir at `/dst`. A host `cp` would not do: the kernel
       resolves the `<key>/.` it is given through a swapped link, and GNU
       `cp` walks inner directories by path, so a swap mid-copy is followed
       too, and the host could copy any directory the portal can read into
       the cache. In the container every path and link resolves inside a
       namespace where host directories do not exist. Only `out/` itself is
       a bind source, because docker resolves a bind source on the host; it
       sits in a scratch dir only the host writes. A copy that exits
       non-zero, takes over 60 seconds (the container is killed) or raises
       promotes nothing.
       Everything from here on reads the staging copy, never the source. The
       slug is mounted read-only into every build container, so no build can
       write the copy or reach it through a descriptor on the source. The
       source is left alone for the scratch cleanup.
       The copy container is named `ncc-promote-<hex>`, so a
       `Portal.Workers.Sweep` hex sweep that runs while it exists sees an
       `ncc-*` container and skips once; that is accepted.
    7. The copy must hold only directories, regular files with a link count
       of 1, and Mix's own links (below). It is walked with `File.lstat/1`
       only, so nothing a link points at is ever followed, and listed with
       `:file.list_dir_all/1`, because `File.ls/1` silently drops names that
       are not valid UTF-8 on Linux and such an entry would be promoted
       unchecked. Any such name refuses the candidate: every real Mix
       artifact name is UTF-8. A file hardlinked to one outside the tree is
       an independent file in the copy; GNU `cp -a` keeps a hardlink between
       two names inside the tree, and that is refused.
    8. Setuid, setgid, sticky and group/other write are stripped from every
       directory and regular file in the copy, which is then renamed into
       place. An existing entry is never replaced. Any refusal or error
       removes the copy; `Portal.Workers.Sweep` prunes staging names
       (`Portal.BuildCache.Staging`) a crash left behind, once old enough.

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
  alias Portal.BuildCache.{Staging, Tree}

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
  is used, then `Portal.HexPm.release_checksum/2`. `opts[:image]` is the
  worker image the build ran (`Portal.Builder.worker_image_ref/1`), which
  the copy runs in; without it nothing is promoted. `opts[:copy]` (or the same
  `config` key) replaces that container copy with
  `fn source, staging -> :ok | {:error, term}`, and
  `opts[:staging_suffix]` pins the staging name's random suffix: seams for
  tests.
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
      toolchain: toolchain(result),
      copy: Keyword.get_lazy(opts, :copy, fn -> default_copy(opts[:image]) end),
      staging_suffix:
        case opts[:staging_suffix] do
          nil -> nil
          suffix -> fn -> suffix end
        end
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

  # Every container-chosen string reaches the log through here (see `Tree.show/1`).
  defp show(term), do: Tree.show(term)

  @doc false
  defdelegate name_string(name), to: Tree

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

  defp default_copy(image) do
    :portal
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:copy, {:container, image})
  end

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

  # Steps 6 to 8.
  defp check_tree_and_move(c, key, ctx) do
    case check_source(key, ctx) do
      :ok ->
        copy_check_move(c, key, ctx)

      {:error, reason} ->
        refuse_tree(key, ctx, reason)
    end
  end

  defp refuse_tree(key, ctx, reason) do
    Logger.warning(
      "Build cache candidate #{key} for #{ctx.package} #{ctx.version} refused: #{reason}"
    )

    :refused
  end

  # Only the directories leading to the candidate. Its contents are checked
  # on the host-private copy, in `copy_check_move/3`.
  # `out` is the run's scratch output dir (operator config + run id); `key`
  # is a 64-hex string this module computed, never the container's.
  # sobelow_skip ["Traversal.FileModule"]
  defp check_source(key, ctx) do
    parent = Path.join(ctx.out, "build-cache")
    source = Path.join(parent, key)

    with {:ok, %File.Stat{type: :directory} = out} <- lstat(ctx.out),
         {:ok, %File.Stat{type: :directory}} <- lstat(parent),
         {:ok, %File.Stat{type: :directory} = src} <- lstat(source),
         true <- same_device?(out, src) || {:error, "not on the output directory's device"} do
      :ok
    else
      {:ok, %File.Stat{type: type}} -> {:error, "not a directory (#{type})"}
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, "cannot stat: #{inspect(reason)}"}
    end
  end

  defp same_device?(a, b),
    do: a.major_device == b.major_device and a.minor_device == b.minor_device

  # `cache` is the per-image slug dir under the operator's cache root; `key`
  # is the host-computed 64-hex key; the staging suffix is host random.
  # sobelow_skip ["Traversal.FileModule"]
  defp copy_check_move(c, key, ctx) do
    dest = Path.join(ctx.cache, key)

    case lstat(dest) do
      {:ok, _exists} ->
        :skipped

      {:error, _} ->
        staging =
          case ctx.staging_suffix do
            nil -> Staging.name(dest)
            suffix -> dest <> ".tmp." <> suffix.()
          end

        # Only a staging dir this call created is ever removed: `:eexist`
        # means another promotion of the same key holds that name.
        with :ok <- File.mkdir_p(ctx.cache),
             :ok <- make_staging(staging) do
          promote_staged(c, key, staging, dest, ctx)
        else
          error -> not_promoted(key, ctx, error)
        end
    end
  end

  # `staging` was created by this call, so every way out removes it.
  # sobelow_skip ["Traversal.FileModule"]
  defp promote_staged(c, key, staging, dest, ctx) do
    case copy_and_check(key, staging, ctx) do
      :ok ->
        finish(c, key, staging, dest, ctx)

      {:refused, reason} ->
        _ = File.rm_rf(staging)
        refuse_tree(key, ctx, reason)

      error ->
        _ = File.rm_rf(staging)
        not_promoted(key, ctx, error)
    end
  end

  @doc false
  # The staging dir, created fresh: `{:error, :eexist}` when the name is taken.
  # `staging` is built in `copy_check_move/3` from the slug dir, the host key
  # and a host-random suffix.
  # sobelow_skip ["Traversal.FileModule"]
  @spec make_staging(Path.t()) :: :ok | {:error, File.posix()}
  def make_staging(staging), do: File.mkdir(staging)

  defp copy_and_check(key, staging, ctx) do
    with :ok <- copy(key, staging, ctx) do
      case Tree.check(staging, package: ctx.package) do
        :ok -> :ok
        {:error, reason} -> {:refused, reason}
      end
    end
  end

  defp copy(key, staging, %{copy: fun} = ctx) when is_function(fun, 2),
    do: fun.(Path.join([ctx.out, "build-cache", key]), staging)

  defp copy(_key, _staging, %{copy: {:container, nil}}), do: {:error, :no_image}

  defp copy(key, staging, %{copy: {:container, image}} = ctx),
    do: container_copy(ctx.out, staging, key, image)

  # sobelow_skip ["Traversal.FileModule"]
  defp finish(c, key, staging, dest, ctx) do
    with :ok <- Tree.strip_modes(staging),
         :ok <- File.rename(staging, dest) do
      Logger.info(
        "Promoted build cache entry #{key} for #{ctx.package} #{ctx.version} " <>
          "(#{show(c["target"])})"
      )

      :promoted
    else
      error ->
        _ = File.rm_rf(staging)
        not_promoted(key, ctx, error)
    end
  end

  defp not_promoted(key, ctx, error) do
    Logger.warning(
      "Could not promote build cache entry #{key} for #{ctx.package} " <>
        "#{ctx.version}: #{show(error)}"
    )

    :skipped
  end

  @copy_timeout_ms 60_000

  @doc false
  # The `docker run` argument list for the copy (moduledoc, step 6). Pure
  # apart from the random container name, so tests can read it.
  #
  # The bind source is the run's `out/`, never `out/build-cache/<key>`:
  # docker resolves a bind source on the host and would follow a link
  # swapped in there, while `out/` itself sits in a scratch dir only the host
  # writes. Everything below it resolves inside the container, where no host
  # directory exists. `key` is the host-recomputed key.
  @spec copy_args(Path.t(), Path.t(), String.t(), String.t(), String.t()) :: [String.t()]
  def copy_args(out_dir, staging, key, image, name \\ copy_container_name()) do
    [
      "run",
      "--rm",
      "--pull=never",
      "--name",
      name,
      "--network",
      "none",
      "--read-only",
      "--cap-drop=ALL",
      "--security-opt=no-new-privileges",
      "--pids-limit",
      "64",
      "--user",
      Portal.Builder.run_as_user(),
      "--mount",
      "type=bind,source=#{out_dir},target=/src,readonly",
      "--mount",
      "type=bind,source=#{staging},target=/dst",
      "--entrypoint",
      "cp",
      image,
      "-a",
      "/src/build-cache/#{key}/.",
      "/dst"
    ]
  end

  defp copy_container_name,
    do: "ncc-promote-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

  # Fails closed: a non-zero exit, a timeout (the container is killed) or an
  # exception is a failed copy, and the caller removes the staging dir.
  defp container_copy(out_dir, staging, key, image) do
    name = copy_container_name()
    args = copy_args(out_dir, staging, key, image, name)
    task = Task.async(fn -> docker(args) end)

    case Task.yield(task, @copy_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {_out, 0}} ->
        :ok

      {:ok, {out, status}} ->
        {:error, {:copy_container, status, String.slice(out, 0, 500)}}

      {:exit, reason} ->
        {:error, {:copy_container, reason}}

      nil ->
        _ = docker(["kill", name])
        {:error, {:copy_container, :timeout}}
    end
  end

  # Every argument is host-built: the operator's scratch and cache paths, the
  # host-recomputed key, the configured worker image and a host-random name.
  # Passed as a list, no shell.
  # sobelow_skip ["CI.System"]
  defp docker(args) do
    System.cmd("docker", args, stderr_to_stdout: true)
  rescue
    e -> {Exception.message(e), -1}
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp lstat(path), do: File.lstat(path)
end
