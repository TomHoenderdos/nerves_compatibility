defmodule NccWorker.HostNative do
  @moduledoc """
  A host-native run's verdict (`mode: "host_native"`, `NccWorker.RunScope`,
  design addendum for #85): a NIF package built on a toolchain image for
  this builder's own glibc Linux triple (`Compatibility.HostTriple`), whose
  beams and priv native files a client on the same triple may install when
  it opted in. The run itself is `NccWorker.Worker`'s (a plain project, the
  package, the traced host compile with `target: "host", host_native: true`,
  `NccWorker.Portability`); this module judges what it built and describes
  it as `host_native_build`.

  A build passes only when the trace passed and all of these hold, the
  first failure being the reason:

    * the package's beams: at least one, scanned whole, Elixir or Erlang;
    * its priv, walked as `NccWorker.StaticPriv.read/3` walks it (one link
      to its own source priv, regular files with one link, at most 500
      files and 128 MiB): every file that is not ELF is static data its
      verified Hex tarball carries (`Compatibility.StaticPriv`), and every
      ELF file is a 64-bit `ET_DYN` object of the triple's machine
      (`Compatibility.Elf`), at most 64 MiB, and no file it publishes
      outside priv is ELF;
    * that tarball ships checksum files (a downloader: rustler_precompiled,
      elixir_make's precompilers), and every ELF file is a member of an
      archive in the run's own cache dirs whose bytes have the sum a
      checksum file lists for its name (`Compatibility.NifOrigin`); those
      archives are archived too, and `origins` names them. A package with
      no checksum file compiled its native files in this run, and those are
      refused (`Compatibility.NifOrigin.compiled_refusal/1`): nothing checks
      the CPU features its build flags assumed of the builder.

  The beams and the native files ship as one build, so the pair is
  consistent by construction. `native_files` records each ELF file's facts
  for the record; the portal recomputes them from the archived blobs.
  """

  alias Compatibility.{Elf, HostTriple, NifOrigin}
  alias Compatibility.Portability, as: Reasons
  alias Compatibility.StaticPriv, as: Rules
  alias NccWorker.{AppFile, BeamScan, DepsLock, HexCache, Portability, Worker}
  alias NccWorker.StaticPriv, as: PrivFiles

  @libc "glibc"
  @max_priv_files 500
  @max_priv_bytes 128 * 1024 * 1024
  @max_elf 64 * 1024 * 1024
  # The cache walk for downloaded archives: how deep and how many entries.
  @max_cache_depth 6
  @max_cache_entries 20_000
  @unverifiable "ships native files whose checksum file could not be read"

  @doc """
  This builder's triple, checked against the input's `triple` when it names
  one: `{:ok, triple}`, or `{:error, reason}` for a builder that is no glibc
  Linux x86_64/aarch64 or that the job did not ask for (a worker error, exit
  10: the portal retries it elsewhere).
  """
  @spec own_triple(map(), term()) :: {:ok, String.t()} | {:error, term()}
  def own_triple(input, system_architecture \\ :erlang.system_info(:system_architecture)) do
    case {HostTriple.normalize(system_architecture), input[:triple]} do
      {{:ok, triple}, asked} when asked in [nil, triple] -> {:ok, triple}
      {{:ok, triple}, asked} -> {:error, {:host_native_triple, triple, asked}}
      {:error, _asked} -> {:error, {:no_host_native_triple, to_string(system_architecture)}}
    end
  end

  @doc """
  What this VM's build is for besides its triple: the full OTP version
  (`releases/<major>/OTP_VERSION`), the NIF version and the builder's glibc
  (`getconf GNU_LIBC_VERSION`, informational; nil when unknown).
  """
  @spec facts() :: %{otp_full: String.t() | nil, nif_version: String.t(), glibc: String.t() | nil}
  def facts do
    %{
      otp_full: otp_full(),
      nif_version: List.to_string(:erlang.system_info(:nif_version)),
      glibc: glibc()
    }
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp otp_full do
    major = List.to_string(:erlang.system_info(:otp_release))
    path = Path.join([:code.root_dir() |> List.to_string(), "releases", major, "OTP_VERSION"])

    case File.read(path) do
      {:ok, text} -> if version?(String.trim(text)), do: String.trim(text)
      _ -> nil
    end
  end

  defp version?(text), do: Regex.match?(~r/\A\d+(\.\d+)*\z/, text)

  # sobelow_skip ["CI.System"]
  defp glibc do
    case System.cmd("getconf", ["GNU_LIBC_VERSION"], stderr_to_stdout: true) do
      {"glibc " <> version, 0} -> if version?(String.trim(version)), do: String.trim(version)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @doc """
  The run's `host_native_build` from its host compile (`host_result`), the
  package's host build under `<project_dir>/_build/host/lib/<package>`, and
  the trace's verdict (`portability`, nil when there was none). Options:
  `triple:` (required), `otp_full:`, `nif_version:`, `glibc:` (`facts/0`),
  `hex_home:` (the Hex cache holding the package's tarball, default
  `HEX_HOME`), `cache_dirs:` (where downloaded archives are looked for,
  default `cache_dirs/0`) and the run's judge options for
  `Portability.judge_revision/1`. A pass also carries `:archives`, the
  `{path, entry}` of each verified archive for `NccWorker.FileArchiver`,
  which the result never writes.
  """
  @spec build(String.t(), String.t(), map(), map(), Portability.verdict() | nil, keyword()) ::
          map()
  def build(project_dir, package, host_result, toolchain, portability, opts) do
    base = %{
      status: "error",
      reason: nil,
      triple: Keyword.fetch!(opts, :triple),
      libc: @libc,
      glibc: opts[:glibc],
      elixir: toolchain.elixir,
      otp: toolchain.erlang,
      otp_full: opts[:otp_full],
      nif_version: opts[:nif_version],
      deps_lock: nil,
      package_checksum: nil,
      declared: nil,
      compile_env: nil,
      compile_env_rule: nil,
      compile_inputs: nil,
      portability_rule: nil,
      judge_revision: nil,
      manager: nil,
      compile_observations: nil,
      file_manifest: nil,
      native_files: nil,
      origins: nil
    }

    case host_result do
      %{status: :pass} -> judged(base, project_dir, package, portability, host_result, opts)
      host -> %{base | reason: "host compile failed: " <> describe(host[:error])}
    end
  end

  defp describe(error) when is_binary(error), do: error
  defp describe(nil), do: "unknown error"
  defp describe(error), do: inspect(error, limit: 20)

  defp judged(base, project_dir, package, portability, host_result, opts) do
    verdict = require_inputs(portability || not_traced())

    build = %{
      base
      | deps_lock: DepsLock.read(project_dir, package),
        package_checksum: DepsLock.package_checksum(project_dir, package),
        declared: DepsLock.declared(project_dir, package),
        portability_rule: 2,
        judge_revision: Portability.judge_revision(opts),
        manager: verdict[:manager],
        compile_observations: with_host_time(verdict[:observations], host_result)
    }

    if unfinished?(verdict),
      do: %{build | status: "skipped", reason: Reasons.could_not_judge()},
      else: finished(build, project_dir, package, verdict, opts)
  end

  defp finished(build, project_dir, package, verdict, opts) do
    app_dir = Path.join([project_dir, "_build", "host", "lib", package])
    scan = scan(app_dir)
    app_env = AppFile.read_compile_env(Path.join([app_dir, "ebin", "#{package}.app"]))
    {compile_env, rule} = Worker.r5_compile_env(app_env, verdict)
    build = %{build | compile_env: compile_env, compile_env_rule: rule}

    static =
      with :ok <- beam_rules(scan),
           {:ok, tarball} <- tarball(project_dir, package, opts[:hex_home]),
           {:ok, manifest, natives} <-
             priv_rules(app_dir, project_dir, package, scan, tarball, build.triple),
           :ok <- outside_priv(app_dir, manifest),
           {:ok, origins, archives} <- origins(natives, tarball, opts) do
        {:ok, %{manifest: manifest, natives: natives, origins: origins, archives: archives}}
      end

    case Worker.combine(rule_of(static), verdict) do
      :ok ->
        {:ok, passed} = static

        build
        |> Map.merge(%{
          status: "pass",
          compile_inputs: verdict.compile_inputs,
          file_manifest: passed.manifest,
          native_files: passed.natives,
          origins: passed.origins
        })
        |> Map.put(:archives, passed.archives)

      {:skip, reason} ->
        %{build | status: "skipped", reason: reason}
    end
  end

  defp rule_of({:ok, _passed}), do: :ok
  defp rule_of({:skip, _reason} = skip), do: skip

  # A pass names the config and env reads its files depend on; one that
  # does not could have dropped them and never publishes.
  defp require_inputs(%{status: :pass, compile_env: env, compile_inputs: inputs} = verdict)
       when is_list(env) and is_list(inputs),
       do: verdict

  defp require_inputs(%{status: :pass} = verdict) do
    observations = Map.get(verdict, :observations) || %{}
    problems = ["pass without config reads or compile inputs" | observations["problems"] || []]

    verdict
    |> Map.merge(%{status: :skip, reason: Reasons.could_not_judge()})
    |> Map.put(:observations, Map.put(observations, "problems", problems))
  end

  defp require_inputs(verdict), do: verdict

  defp not_traced do
    %{
      status: :skip,
      reason: Reasons.could_not_judge(),
      observations: %{
        "problems" => ["not traced"],
        "trace_stats" => %{"judge_compile" => "not_run", "transient" => true}
      }
    }
  end

  defp unfinished?(%{status: :pass}), do: false

  defp unfinished?(verdict),
    do:
      get_in(verdict, [:observations, "trace_stats", "judge_compile"]) not in [
        "finished",
        "not_run"
      ]

  defp with_host_time(observations, host_result) do
    observations = observations || %{}
    stats = Map.get(observations, "trace_stats") || %{}

    Map.put(
      observations,
      "trace_stats",
      Map.put(stats, "host_compile_sec", host_result[:duration_sec])
    )
  end

  # The raw `BeamScanner` result; a missing or unreadable build reads as no
  # beams.
  defp scan(app_dir) do
    if File.dir?(app_dir), do: BeamScanner.analyze(app_dir), else: %{beam_count: 0}
  rescue
    _ -> %{beam_count: 0}
  end

  defp beam_rules(%{beam_count: count, errors: [], languages: languages})
       when is_integer(count) and count > 0 do
    case Enum.reject(languages, &(&1 in [:elixir, :erlang])) do
      [] -> :ok
      [language | _] -> {:skip, "beam language #{language} is not portable"}
    end
  end

  defp beam_rules(%{beam_count: 0}), do: {:skip, "no compiled beams"}
  defp beam_rules(_scan), do: {:skip, "beam scan incomplete"}

  # The package's own Hex tarball, used only while it is still the one the
  # lock names: its checksum files and static priv data are judged from it.
  defp tarball(project_dir, package, home) do
    with {:ok, release} <- DepsLock.package_release(project_dir, package),
         home when is_binary(home) and home != "" <- home || System.get_env("HEX_HOME"),
         bytes when is_binary(bytes) <-
           HexCache.package_tarball(home, release.name, release.version, release.checksum) do
      {:ok, bytes}
    else
      _ -> {:skip, "no verified Hex tarball for the package"}
    end
  end

  defp priv_rules(app_dir, project_dir, package, scan, tarball, triple) do
    priv = Path.join(app_dir, "priv")
    source = Path.join([project_dir, "deps", package, "priv"])
    caps = [max_files: @max_priv_files, max_bytes: @max_priv_bytes]

    with {:ok, files} <- PrivFiles.read(priv, source, caps),
         {elf, static} = Enum.split_with(files, &elf?(&1.bytes)),
         :ok <- if(elf == [], do: {:skip, "ships no native file"}, else: :ok),
         :ok <- static_rules(static, tarball),
         {:ok, natives} <- elf_rules(elf, triple),
         {:ok, manifest} <- manifest(scan, files) do
      {:ok, manifest, natives}
    end
  end

  # Every native file the build publishes is judged in priv: an ELF file
  # under any other key (a Makefile writing into ebin, which a beam can
  # `load_nif` from) would escape the ELF rules and the origin check.
  defp outside_priv(app_dir, manifest) do
    manifest
    |> Enum.reject(fn {key, _entries} -> key == "priv" end)
    |> Enum.flat_map(fn {_key, entries} -> List.wrap(entries) end)
    |> Enum.map(& &1["path"])
    |> Enum.sort()
    |> Enum.find(&(not is_binary(&1) or elf_file?(Path.join(app_dir, &1))))
    |> case do
      nil -> :ok
      path -> {:skip, "ships a native file outside priv (#{path})"}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp elf_file?(path) do
    case File.open(path, [:read, :binary], &IO.binread(&1, 4)) do
      {:ok, head} -> elf?(head)
      _ -> true
    end
  end

  defp elf?(<<0x7F, "ELF", _::binary>>), do: true
  defp elf?(_bytes), do: false

  defp static_rules([], _tarball), do: :ok

  defp static_rules(files, tarball) do
    case Rules.check(files, tarball) do
      :ok -> :ok
      {:error, reason, _details} -> {:skip, reason}
    end
  end

  defp elf_rules(files, triple) do
    {:ok, machine} = HostTriple.elf_machine(triple)

    files
    |> Enum.sort_by(& &1.path)
    |> Enum.reduce_while({:ok, []}, fn file, {:ok, acc} ->
      case loadable(file.bytes, machine) do
        {:ok, info} ->
          {:cont, {:ok, [native_file(file, info) | acc]}}

        :error ->
          {:halt, {:skip, "ships a native file #{triple} cannot load (priv/#{file.path})"}}
      end
    end)
    |> then(fn
      {:ok, natives} -> {:ok, Enum.reverse(natives)}
      skip -> skip
    end)
  end

  defp loadable(bytes, machine) when byte_size(bytes) <= @max_elf do
    case Elf.read(bytes) do
      {:ok, %{class: 64, type: :dyn, machine: ^machine} = info} -> {:ok, info}
      _ -> :error
    end
  end

  defp loadable(_bytes, _machine), do: :error

  defp native_file(file, info) do
    %{
      "path" => "priv/" <> file.path,
      "sha256" => sha256(file.bytes),
      "size" => byte_size(file.bytes),
      "class" => info.class,
      "machine" => Atom.to_string(info.machine),
      "soname" => info.soname,
      "needed" => info.needed,
      "needs" => info.needs
    }
  end

  # The scan's manifest, which `NccWorker.FileArchiver` archives from, must
  # list exactly the priv files judged here, byte for byte.
  defp manifest(scan, files) do
    manifest = BeamScan.normalize(scan)["footprint"]["file_manifest"]
    listed = for e <- manifest["priv"] || [], into: MapSet.new(), do: {e["path"], e["sha256"]}
    judged = for f <- files, into: MapSet.new(), do: {"priv/" <> f.path, sha256(f.bytes)}

    if listed == judged,
      do: {:ok, manifest},
      else: {:skip, "priv changed while it was judged"}
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  # A downloader's native files must each come from an archive its checksum
  # files pin (`Compatibility.NifOrigin`); a package with none compiled them
  # in the run, which is refused (`NifOrigin.compiled_refusal/1`).
  defp origins([first | _] = natives, tarball, opts) do
    case NifOrigin.checksum_files(tarball) do
      {:ok, checksums} when map_size(checksums) == 0 ->
        {:skip, NifOrigin.compiled_refusal(first["path"])}

      {:ok, checksums} ->
        verify(natives, checksums, Keyword.get_lazy(opts, :cache_dirs, &cache_dirs/0))

      :error ->
        {:skip, @unverifiable}
    end
  end

  defp verify(natives, checksums, dirs) do
    archives = archives(checksums, dirs)
    files = Enum.map(natives, &Map.take(&1, ["path", "sha256"]))
    candidates = Map.new(archives, fn {name, _path, bytes} -> {name, bytes} end)

    case NifOrigin.verify(files, checksums, candidates) do
      {:ok, origins} -> {:ok, origins, archive_entries(origins, archives)}
      {:error, reason} -> {:skip, reason}
    end
  end

  defp archive_entries(origins, archives) do
    used = MapSet.new(origins, & &1["archive"])

    for {name, path, bytes} <- archives, MapSet.member?(used, name) do
      {path, %{"sha256" => sha256(bytes), "size" => byte_size(bytes)}}
    end
  end

  @doc """
  Where the run's compile left the archives it downloaded: its own cache
  dirs (`XDG_CACHE_HOME`, `$HOME/.cache`, and rustler_precompiled's and
  elixir_make's cache variables when set). In the container `$HOME/.cache`
  is the run's own scratch dir. Where an archive was found does not matter:
  only one whose bytes have the listed sum is used.
  """
  @spec cache_dirs() :: [String.t()]
  def cache_dirs do
    home = System.get_env("HOME")

    [
      System.get_env("XDG_CACHE_HOME"),
      home && Path.join(home, ".cache"),
      System.get_env("RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH"),
      System.get_env("ELIXIR_MAKE_CACHE_DIR")
    ]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end

  # `{name, path, bytes}` of the first file in `dirs` for each archive name
  # a checksum file lists, whose bytes have a listed sum for that name.
  defp archives(checksums, dirs) do
    sums =
      Enum.reduce(checksums, %{}, fn {_file, entries}, acc ->
        Enum.reduce(entries, acc, fn {name, sum}, acc ->
          Map.update(acc, name, MapSet.new([sum]), &MapSet.put(&1, sum))
        end)
      end)

    dirs
    |> Enum.flat_map(&candidates(&1, sums))
    |> Enum.reduce([], fn {name, path}, acc ->
      with false <- List.keymember?(acc, name, 0),
           {:ok, bytes} <- read_archive(path),
           true <- MapSet.member?(sums[name], sha256(bytes)) do
        [{name, path, bytes} | acc]
      else
        _ -> acc
      end
    end)
    |> Enum.reverse()
  end

  defp candidates(dir, sums) do
    {found, _count} = walk(dir, 0, sums, {[], 0})
    Enum.sort(found)
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp walk(_dir, depth, _sums, acc) when depth > @max_cache_depth, do: acc
  defp walk(_dir, _depth, _sums, {_found, count} = acc) when count > @max_cache_entries, do: acc

  defp walk(dir, depth, sums, acc) do
    case File.ls(dir) do
      {:ok, names} -> Enum.reduce(Enum.sort(names), acc, &walk_entry(dir, &1, depth, sums, &2))
      _ -> acc
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp walk_entry(dir, name, depth, sums, {found, count}) do
    path = Path.join(dir, name)
    acc = {found, count + 1}

    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        walk(path, depth + 1, sums, acc)

      {:ok, %File.Stat{type: :regular}} when is_map_key(sums, name) ->
        {[{name, path} | found], count + 1}

      _ ->
        acc
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp read_archive(path) do
    max = NifOrigin.max_archive_bytes()

    with {:ok, %File.Stat{type: :regular, size: size}} when size <= max <- File.lstat(path),
         {:ok, bytes} when byte_size(bytes) == size <- File.read(path) do
      {:ok, bytes}
    else
      _ -> :error
    end
  end
end
