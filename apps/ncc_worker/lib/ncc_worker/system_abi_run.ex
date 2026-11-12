defmodule NccWorker.SystemAbiRun do
  @moduledoc """
  A `mode: "system_abi"` run: reports, for each requested Nerves system
  release, the toolchain it locks, the full OTP version it ships and its
  rootfs library table (`NccWorker.SystemAbi`), for releases no current
  build covers. It builds no package and no firmware.

  `NCC_INPUT.system_abi` lists at most 8 `%{"system", "version"}` pairs;
  more, or a list that is not one of such maps, is an input error (exit 10).
  Each pair gets its own generated template project (`NccWorker.Project`,
  as `NccWorker.WarmNerves` makes one) with only that system's target and
  the system pinned to `"== version"`, and runs `mix deps.get` and
  `mix nerves.artifact.get` for the target: Nerves 2 resolves artifacts in
  `Nerves.export_env/0`, which `nerves.artifact.get` runs. Like a build, and
  unlike a warm, the run resolves them through the per-run symlink farm over
  the read-only `/nerves-cache` (`NccWorker.NervesCache`) and never writes
  the cache: what the cache lacks is extracted into the run's own dir.

  Every pair has an entry in the result's `system_abi`, in input order:
  `%{"system", "version", "toolchain", "otp_full", "system_libs"}`, or, for a
  pair any of the three could not be read for, only `"system"`, `"version"`
  and a short `"error"`: "unknown system", "invalid version",
  "project failed", "deps.get failed", "nerves.artifact.get failed",
  "no artifact", "no toolchain", "no OTP version", "no rootfs",
  "no libc in rootfs" or "internal error". One pair failing never stops the
  next.
  """

  alias NccWorker.{Argus, DepsLock, Project, SystemAbi, Systems, WarmNerves}

  @max_pairs 8
  @lib_opts [:runner, :unsquashfs, :timeout_sec, :tmp_dir]

  @type entry :: %{String.t() => String.t() | map()}

  @doc """
  Runs the pairs of `input.system_abi`.

  Options: `:paths` (the worker's `%{work_dir, output_dir}`), `:toolchain`
  (the detected toolchain, echoed as the result's), `:artifacts_dir`
  (default `NERVES_ARTIFACTS_DIR`), `:create_project` and `:mix` (in place
  of `Project.create/3` and the `mix` runner, in tests), and
  `SystemAbi.rootfs_libs/2`'s `:runner`, `:unsquashfs`, `:timeout_sec` and
  `:tmp_dir`.
  """
  @spec run(map(), keyword()) :: {:ok, map()} | {:error, :too_many_pairs | :invalid_pairs}
  def run(input, opts) do
    with {:ok, pairs} <- validate(input[:system_abi]) do
      paths = Keyword.fetch!(opts, :paths)

      ctx = %{
        work_dir: paths.work_dir,
        log_file: Path.join([paths.output_dir, "logs", "system_abi.log"]),
        artifacts:
          Keyword.get_lazy(opts, :artifacts_dir, fn -> System.get_env("NERVES_ARTIFACTS_DIR") end),
        create: Keyword.get(opts, :create_project, &Project.create/3),
        mix: Keyword.get(opts, :mix, &WarmNerves.run_mix/4),
        lib_opts: Keyword.take(opts, @lib_opts)
      }

      entries =
        pairs
        |> Enum.with_index()
        |> Enum.map(fn {pair, index} -> entry(pair, index, ctx) end)

      {:ok, result(input, Keyword.get(opts, :toolchain), entries)}
    end
  end

  @doc """
  `{:ok, pairs}` when `pairs` is a list of at most #{@max_pairs} maps with a string
  `"system"` and `"version"`, else the input error.
  """
  @spec validate(term()) :: {:ok, [map()]} | {:error, :too_many_pairs | :invalid_pairs}
  def validate(pairs) when is_list(pairs) do
    cond do
      not Enum.all?(pairs, &pair?/1) -> {:error, :invalid_pairs}
      length(pairs) > @max_pairs -> {:error, :too_many_pairs}
      true -> {:ok, pairs}
    end
  end

  def validate(_pairs), do: {:error, :invalid_pairs}

  defp pair?(%{"system" => system, "version" => version})
       when is_binary(system) and is_binary(version),
       do: true

  defp pair?(_pair), do: false

  defp entry(%{"system" => name, "version" => version} = pair, index, ctx) do
    base = %{"system" => name, "version" => version}

    case resolve(pair, index, ctx) do
      {:ok, facts} -> Map.merge(base, facts)
      {:error, why} -> Map.put(base, "error", why)
    end
  rescue
    e ->
      IO.puts(:stderr, "Warning: system_abi #{name}: #{Exception.message(e)}")
      %{"system" => name, "version" => version, "error" => "internal error"}
  end

  defp resolve(%{"system" => name, "version" => version}, index, ctx) do
    with {:ok, system} <- system(name),
         :ok <- version(version) do
      work_dir = Path.join([ctx.work_dir, "system_abi", Integer.to_string(index)])

      try do
        facts(system, version, work_dir, ctx)
      after
        remove(work_dir)
      end
    end
  end

  defp system(name) do
    case Enum.find(Systems.all(), &(&1.name == name)) do
      nil -> {:error, "unknown system"}
      system -> {:ok, system}
    end
  end

  defp version(version) do
    if byte_size(version) <= 64 and match?({:ok, _}, Version.parse(version)),
      do: :ok,
      else: {:error, "invalid version"}
  end

  defp facts(system, version, work_dir, ctx) do
    with {:ok, project_dir} <- project(system, version, work_dir, ctx),
         env = WarmNerves.target_env(project_dir, system),
         :ok <- step(ctx, ["deps.get"], project_dir, env),
         :ok <- step(ctx, ["nerves.artifact.get"], project_dir, env),
         {:ok, dir} <- artifact(ctx.artifacts, system.name, version),
         {:ok, toolchain} <- toolchain(project_dir, system.name),
         {:ok, otp} <- otp(dir),
         {:ok, libs} <- libs(dir, ctx.lib_opts) do
      {:ok, %{"toolchain" => toolchain, "otp_full" => otp, "system_libs" => libs}}
    end
  end

  defp project(system, version, work_dir, ctx) do
    case ctx.create.(work_dir, %{system.name => "== " <> version}, [system.target]) do
      {:ok, project_dir} ->
        {:ok, project_dir}

      other ->
        IO.puts(:stderr, "Warning: system_abi #{system.name}: project: #{inspect(other)}")
        {:error, "project failed"}
    end
  end

  defp step(ctx, args, project_dir, env) do
    case ctx.mix.(args, project_dir, env, ctx.log_file) do
      :ok -> :ok
      {:error, _code} -> {:error, Enum.join(args, " ") <> " failed"}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp artifact(artifacts, name, version) when is_binary(artifacts) do
    dir = SystemAbi.artifact_dir(artifacts, name, version)
    if File.dir?(dir), do: {:ok, dir}, else: {:error, "no artifact"}
  end

  defp artifact(_artifacts, _name, _version), do: {:error, "no artifact"}

  defp toolchain(project_dir, name) do
    with {:ok, lock} <- DepsLock.lock(project_dir),
         %{} = toolchain <- SystemAbi.toolchain(lock, name) do
      {:ok, toolchain}
    else
      _ -> {:error, "no toolchain"}
    end
  end

  defp otp(dir) do
    case SystemAbi.otp(dir) do
      nil -> {:error, "no OTP version"}
      otp -> {:ok, otp}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp libs(dir, lib_opts) do
    cond do
      not File.regular?(Path.join([dir, "images", "rootfs.squashfs"])) ->
        {:error, "no rootfs"}

      libs = SystemAbi.rootfs_libs(dir, lib_opts) ->
        {:ok, libs}

      true ->
        {:error, "no libc in rootfs"}
    end
  end

  # The pair's own scratch dir under the /work mount; the name is fixed.
  # sobelow_skip ["Traversal.FileModule"]
  defp remove(work_dir) do
    File.rm_rf(work_dir)
    :ok
  end

  defp result(input, toolchain, entries) do
    %{
      run_id: input.run_id,
      package: nil,
      image: input.image,
      toolchain: toolchain,
      systems: %{},
      argus: Argus.skipped(),
      finished_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      scope: "system_abi",
      system_abi: entries
    }
  end
end
