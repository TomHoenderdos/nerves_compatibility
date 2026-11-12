defmodule NccWorker.SystemAbi do
  @moduledoc """
  What a passing target's Nerves system release offers a precompiled NIF:
  the toolchain its lock resolved, the full OTP version it ships, and the
  shared libraries its rootfs has, each with the symbol versions it defines.
  The portal matches a NIF built on one release against another release of
  the same system by these three facts.

  All of it is advisory. Whatever goes wrong leaves a fact out of the
  target's result, logged, and never changes a status (`put/4`).

  The artifact directory is the one Nerves resolved the system through:
  `<NERVES_ARTIFACTS_DIR>/<name>-<version>` (`NccWorker.NervesCache`), a link
  into the read-only cache or a directory the run extracted itself.

  The library table comes from the release's `images/rootfs.squashfs`:
  `unsquashfs` extracts `lib` and `usr/lib` into a temporary directory, and
  every regular `*.so` or `*.so.*` there is read with
  `Compatibility.Elf.read_file/1`. A table without `libc.so.6` or `libc.so`
  is the sign of a failed or partial extraction and is never reported, so a
  missing table can never read as "no libraries".
  """

  alias Compatibility.Elf
  alias NccWorker.NervesCache

  @otp_glob "staging/usr/lib/erlang/releases/*/OTP_VERSION"
  @lib_roots ["lib", "usr/lib"]
  @libc ["libc.so.6", "libc.so"]
  @max_files 5000
  @max_depth 32
  @max_hops 40
  @timeout_sec 120

  @type libs :: %{String.t() => [String.t()]}

  @doc """
  Adds `toolchain`, `otp_full` and `system_libs` to every passing system of
  `systems` whose version is known; `system_libs` only when
  `"<name>@<version>"` is not in `known`. Each fact is computed on its own,
  and one that fails or is unknown is left out.

  Options: `:artifacts_dir` (default `NERVES_ARTIFACTS_DIR`), `:concurrency`
  (default 1), and `rootfs_libs/2`'s.
  """
  @spec put(map(), map(), [String.t()], keyword()) :: map()
  def put(systems, lock, known, opts \\ []) do
    artifacts =
      Keyword.get_lazy(opts, :artifacts_dir, fn -> System.get_env("NERVES_ARTIFACTS_DIR") end)

    systems
    |> Task.async_stream(
      fn {name, result} -> {name, put_one(name, result, lock, known, artifacts, opts)} end,
      max_concurrency: Keyword.get(opts, :concurrency, 1),
      timeout: :infinity
    )
    |> Enum.zip(systems)
    |> Map.new(fn
      {{:ok, entry}, _} -> entry
      {{:exit, _reason}, entry} -> entry
    end)
  end

  defp put_one(name, %{status: :pass, system_version: version} = result, lock, known, root, opts)
       when is_binary(version) do
    dir = if is_binary(root), do: artifact_dir(root, name, version)
    known? = "#{name}@#{version}" in known

    result
    |> put_fact(:toolchain, name, fn -> toolchain(lock, name) end)
    |> put_fact(:otp_full, name, fn -> dir && otp(dir) end)
    |> put_fact(:system_libs, name, fn -> if dir && not known?, do: rootfs_libs(dir, opts) end)
  end

  defp put_one(_name, result, _lock, _known, _root, _opts), do: result

  defp put_fact(result, key, name, fun) do
    case fun.() do
      nil -> result
      value -> Map.put(result, key, value)
    end
  rescue
    e -> warn(name, key, Exception.message(e), result)
  catch
    kind, reason -> warn(name, key, inspect({kind, reason}), result)
  end

  defp warn(name, key, why, result) do
    IO.puts(:stderr, "Warning: #{name}: #{key} left out: #{why}")
    result
  end

  @doc "The artifact directory Nerves resolves `name` `version` through."
  @spec artifact_dir(Path.t(), String.t(), String.t()) :: Path.t()
  def artifact_dir(artifacts_dir, name, version),
    do: Path.join(artifacts_dir, NervesCache.entry_name(%{"name" => name, "version" => version}))

  @doc """
  The locked toolchain of `system_name`: the dependency of its lock entry
  whose name starts with `nerves_toolchain_`, at the version the lock
  resolved it to. nil when either is not in the lock. Keys may be atoms or
  strings.
  """
  @spec toolchain(map(), String.t()) :: %{String.t() => String.t()} | nil
  def toolchain(lock, system_name) do
    lock = Map.new(lock, fn {name, entry} -> {to_string(name), entry} end)

    with entry when is_tuple(entry) and tuple_size(entry) >= 6 <- lock[system_name],
         :hex <- elem(entry, 0),
         deps when is_list(deps) <- elem(entry, 5),
         package when is_binary(package) <- Enum.find_value(deps, &toolchain_dep/1),
         {:hex, _pkg, version, _inner, _managers, _deps, _repo, _outer}
         when is_binary(version) <- lock[package] do
      %{"package" => package, "version" => version}
    else
      _ -> nil
    end
  end

  defp toolchain_dep({dep, _requirement, _opts}) when is_atom(dep) or is_binary(dep) do
    dep = to_string(dep)
    if String.starts_with?(dep, "nerves_toolchain_"), do: dep
  end

  defp toolchain_dep(_dep), do: nil

  @doc """
  The full OTP version a system release ships, from its single
  `staging/usr/lib/erlang/releases/*/OTP_VERSION`; nil without exactly one
  or when it holds no version.
  """
  @spec otp(Path.t()) :: String.t() | nil
  # artifact_dir is the run's own Nerves artifacts dir (`NccWorker.NervesCache`).
  # sobelow_skip ["Traversal.FileModule"]
  def otp(artifact_dir) do
    with [file] <- Path.wildcard(Path.join(artifact_dir, @otp_glob)),
         {:ok, %File.Stat{type: :regular, size: size}} when size <= 64 <- File.stat(file),
         {:ok, content} <- File.read(file),
         version = String.trim(content),
         true <- Regex.match?(~r/\A\d+(\.\d+)*\z/, version) do
      version
    else
      _ -> nil
    end
  end

  @doc """
  The shared libraries of a release's rootfs: every DT_SONAME, file name and
  name of a link to the file, mapped to the symbol versions the file
  defines. nil when the squashfs is absent, `unsquashfs` is missing, fails
  or times out, the tree holds more than #{@max_files} library names, or the
  table has no libc.

  Options: `:runner` (`fn squashfs, dest -> :ok | {:error, term} end`, in
  place of `unsquashfs`), `:unsquashfs` (its path, default found on PATH),
  `:tmp_dir` (default `System.tmp_dir!/0`).
  """
  @spec rootfs_libs(Path.t(), keyword()) :: libs() | nil
  # artifact_dir is the run's own Nerves artifacts dir, the extraction dir a
  # fresh one under the run's own tmp.
  # sobelow_skip ["Traversal.FileModule"]
  def rootfs_libs(artifact_dir, opts \\ []) do
    squashfs = Path.join([artifact_dir, "images", "rootfs.squashfs"])
    tmp = Keyword.get_lazy(opts, :tmp_dir, &System.tmp_dir!/0)
    dest = Path.join(tmp, "ncc-rootfs-#{System.unique_integer([:positive])}")

    found =
      with true <- File.regular?(squashfs) || {:error, :no_squashfs},
           {:ok, runner} <- runner(opts) do
        extract(runner, squashfs, dest)
      end

    outcome(found, artifact_dir)
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp extract(runner, squashfs, dest) do
    with :ok <- runner.(squashfs, dest), do: table(dest)
  after
    File.rm_rf(dest)
  end

  defp outcome({:ok, libs}, _dir), do: libs

  defp outcome({:error, :no_squashfs}, _dir), do: nil

  defp outcome(other, dir) do
    IO.puts(:stderr, "Warning: no library table for #{Path.basename(dir)}: #{inspect(other)}")
    nil
  end

  defp runner(opts) do
    case Keyword.fetch(opts, :runner) do
      {:ok, runner} ->
        {:ok, runner}

      :error ->
        exe = Keyword.get_lazy(opts, :unsquashfs, fn -> System.find_executable("unsquashfs") end)

        if is_binary(exe) and File.regular?(exe),
          do: {:ok, &unsquash(exe, &1, &2)},
          else: {:error, :no_unsquashfs}
    end
  end

  # Under `timeout(1)` when the image has it, so the process itself dies at
  # the limit; the task's own limit is the backstop.
  defp unsquash(exe, squashfs, dest) do
    args = ["-n", "-d", dest, squashfs | @lib_roots]

    {command, argv} =
      case System.find_executable("timeout") do
        nil -> {exe, args}
        timeout -> {timeout, ["--kill-after=10", "#{@timeout_sec}", exe | args]}
      end

    task = Task.async(fn -> run(command, argv) end)

    case Task.yield(task, (@timeout_sec + 15) * 1000) || Task.shutdown(task, :brutal_kill) do
      {:ok, {_output, 0}} -> :ok
      {:ok, {:error, reason}} -> {:error, reason}
      {:ok, {output, code}} -> {:error, {:unsquashfs_exit, code, String.slice(output, -500..-1)}}
      nil -> {:error, :timeout}
    end
  end

  # A fixed executable (unsquashfs, or timeout running it) and a literal
  # argument list: the run's own squashfs and extraction dir, no shell.
  # sobelow_skip ["CI.System"]
  defp run(command, argv) do
    System.cmd(command, argv, stderr_to_stdout: true)
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp table(root) do
    found =
      @lib_roots
      |> Enum.filter(&real_dir?(root, &1))
      |> Enum.reduce(%{files: [], links: [], count: 0}, &walk(root, &1, &2, 0))

    libs = libs(root, found)

    if Enum.any?(@libc, &Map.has_key?(libs, &1)),
      do: {:ok, libs},
      else: {:error, :no_libc}
  catch
    :too_many -> {:error, :too_many_files}
  end

  # Every component a real directory, so the walk never leaves the tree:
  # with a merged /usr, `lib` is a link to `usr/lib` and is walked once.
  # sobelow_skip ["Traversal.FileModule"]
  defp real_dir?(root, rel) do
    rel
    |> Path.split()
    |> Enum.scan(&Path.join(&2, &1))
    |> Enum.all?(&match?({:ok, %File.Stat{type: :directory}}, File.lstat(Path.join(root, &1))))
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp walk(_root, _rel, acc, depth) when depth > @max_depth, do: acc

  defp walk(root, rel, acc, depth) do
    case File.ls(Path.join(root, rel)) do
      {:ok, names} -> names |> Enum.sort() |> Enum.reduce(acc, &entry(root, rel, &1, &2, depth))
      {:error, _} -> acc
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp entry(root, dir, name, acc, depth) do
    rel = Path.join(dir, name)

    case File.lstat(Path.join(root, rel)) do
      {:ok, %File.Stat{type: :directory}} -> walk(root, rel, acc, depth + 1)
      {:ok, %File.Stat{type: :regular}} -> if library?(name), do: add(acc, :files, rel), else: acc
      {:ok, %File.Stat{type: :symlink}} -> if library?(name), do: add(acc, :links, rel), else: acc
      _ -> acc
    end
  end

  defp library?(name), do: Regex.match?(~r/\.so(\.|\z)/, name)

  defp add(%{count: count}, _kind, _rel) when count >= @max_files, do: throw(:too_many)

  defp add(acc, kind, rel),
    do: acc |> Map.update!(kind, &[rel | &1]) |> Map.update!(:count, &(&1 + 1))

  # Files in walk order, `lib` before `usr/lib` as the dynamic linker
  # searches them, so a name both have maps to the one it would load.
  defp libs(root, %{files: files, links: links}) do
    defines =
      for rel <- Enum.reverse(files),
          {:ok, info} <- [Elf.read_file(Path.join(root, rel))],
          into: %{},
          do: {rel, info}

    names_by_file =
      for link <- Enum.reverse(links),
          target = resolve(root, link),
          Map.has_key?(defines, target),
          reduce: %{} do
        acc -> Map.update(acc, target, [Path.basename(link)], &(&1 ++ [Path.basename(link)]))
      end

    for rel <- Enum.reverse(files),
        info = defines[rel],
        info != nil,
        name <-
          Enum.reject(
            [info.soname, Path.basename(rel) | Map.get(names_by_file, rel, [])],
            &is_nil/1
          ),
        reduce: %{} do
      acc -> Map.put_new(acc, name, info.defines |> Enum.uniq() |> Enum.sort())
    end
  end

  # Where a link inside the extracted tree points, as a path relative to
  # it: an absolute target is read against the rootfs, and `..` stops at
  # its root. nil for a dangling link or a loop.
  defp resolve(root, rel), do: follow(root, [], Path.split(rel), 0)

  defp follow(_root, _done, _todo, hops) when hops > @max_hops, do: nil
  defp follow(_root, [], [], _hops), do: nil
  defp follow(_root, done, [], _hops), do: Path.join(done)
  defp follow(root, done, ["." | rest], hops), do: follow(root, done, rest, hops)
  defp follow(root, done, [".." | rest], hops), do: follow(root, Enum.drop(done, -1), rest, hops)

  # sobelow_skip ["Traversal.FileModule"]
  defp follow(root, done, [part | rest], hops) do
    next = done ++ [part]
    path = Path.join([root | next])

    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} ->
        case File.read_link(path) do
          {:ok, "/" <> _ = target} ->
            follow(root, [], tl(Path.split(target)) ++ rest, hops + 1)

          {:ok, target} ->
            follow(root, done, Path.split(target) ++ rest, hops + 1)

          {:error, _} ->
            nil
        end

      {:ok, _} ->
        follow(root, next, rest, hops)

      {:error, _} ->
        nil
    end
  end
end
