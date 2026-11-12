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
  "no libc in rootfs", "requires nerves 1" (`deps_get_error/1`), "timeout"
  or "internal error". One pair failing never stops the next.

  Each pair has a deadline, `NCC_SYSTEM_ABI_PAIR_TIMEOUT_SEC` (default
  600 s), over all of its work. Every `mix` runs under `timeout(1)` with
  what is left of it, which kills mix and the process group it runs in, and
  the extraction gets at most what is left too. The pair's work runs in a
  task killed a grace period past the deadline, the backstop for an image
  without `timeout(1)`. A pair past its deadline is `"timeout"`, and the run
  goes on, so a hung `mix` costs one pair and never the result.
  """

  alias NccWorker.{Argus, DepsGetClassifier, DepsLock, Project, SystemAbi, Systems, WarmNerves}

  @max_pairs 8
  @lib_opts [:runner, :unsquashfs, :timeout_sec, :tmp_dir]
  @pair_timeout_sec 600
  @kill_grace_sec 30
  @extract_timeout_sec 120
  @output_tail_bytes 65_536

  # `timeout(1)`'s exit when the command timed out (TERM); 137 is its
  # `--kill-after` SIGKILL, or mix killed otherwise (OOM) before the time.
  @timeout_exit 124
  @killed_exit 137

  # A Hex resolution failure about the `nerves` package itself: the old
  # resolver's `Failed to use "nerves" (...) because` and the newer one's
  # `depends on nerves ~> 1.10`. `\b` keeps `nerves_system_*` and
  # `nerves_toolchain_*` out.
  @nerves_conflict [
    ~r/Failed to use "nerves"/,
    ~r/\bdepends on nerves\b(?!_)/
  ]

  @type entry :: %{String.t() => String.t() | map()}

  @doc """
  Runs the pairs of `input.system_abi`.

  Options: `:paths` (the worker's `%{work_dir, output_dir}`), `:toolchain`
  (the detected toolchain, echoed as the result's), `:artifacts_dir`
  (default `NERVES_ARTIFACTS_DIR`), `:create_project` and `:mix` (in place
  of `Project.create/3` and the `mix` runner, in tests), and
  `SystemAbi.rootfs_libs/2`'s `:runner`, `:unsquashfs`, `:timeout_sec` and
  `:tmp_dir`. `:pair_timeout_sec` (default `NCC_SYSTEM_ABI_PAIR_TIMEOUT_SEC`,
  `pair_timeout_sec/1`) and `:kill_grace_sec` (default #{@kill_grace_sec})
  bound each pair.

  The `:mix` runner is `(args, project_dir, env, log_file, timeout_sec)` and
  returns `:ok`, `{:error, :timeout}` or `{:error, {exit_code, output}}`.
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
        mix: Keyword.get(opts, :mix, &run_mix/5),
        lib_opts: Keyword.take(opts, @lib_opts),
        pair_timeout_sec:
          Keyword.get_lazy(opts, :pair_timeout_sec, fn ->
            pair_timeout_sec(System.get_env("NCC_SYSTEM_ABI_PAIR_TIMEOUT_SEC"))
          end),
        kill_grace_sec: Keyword.get(opts, :kill_grace_sec, @kill_grace_sec)
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

  @doc """
  The per-pair deadline in seconds from `NCC_SYSTEM_ABI_PAIR_TIMEOUT_SEC`'s
  value: a positive integer, else #{@pair_timeout_sec}.
  """
  @spec pair_timeout_sec(String.t() | nil) :: pos_integer()
  def pair_timeout_sec(value) do
    case Integer.parse(value || "") do
      {n, ""} when n > 0 -> n
      _ -> @pair_timeout_sec
    end
  end

  @doc """
  The entry error for a failed `mix deps.get` from its output: "requires
  nerves 1" when Hex could not resolve the release with the template's
  pinned nerves (a permanent failure: the release only accepts Nerves 1),
  else "deps.get failed". A failure `NccWorker.DepsGetClassifier` calls
  transient is never the former.
  """
  @spec deps_get_error(String.t()) :: String.t()
  def deps_get_error(output) when is_binary(output) do
    if DepsGetClassifier.classify(output) == :deterministic and
         Enum.any?(@nerves_conflict, &Regex.match?(&1, output)),
       do: "requires nerves 1",
       else: "deps.get failed"
  end

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
        bounded(fn deadline -> facts(system, version, work_dir, ctx, deadline) end, ctx)
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

  # The pair's work in a task with the pair's deadline, killed a grace
  # period past it. A crash in it is "internal error", never the caller's.
  defp bounded(fun, ctx) do
    deadline = System.monotonic_time(:millisecond) + ctx.pair_timeout_sec * 1000

    task =
      Task.async(fn ->
        try do
          fun.(deadline)
        rescue
          e -> internal(e)
        catch
          kind, reason -> internal({kind, reason})
        end
      end)

    wait_ms = (ctx.pair_timeout_sec + ctx.kill_grace_sec) * 1000

    case Task.yield(task, wait_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, outcome} -> outcome
      {:exit, _reason} -> {:error, "internal error"}
      nil -> {:error, "timeout"}
    end
  end

  defp internal(why) do
    message = if is_exception(why), do: Exception.message(why), else: inspect(why)
    IO.puts(:stderr, "Warning: system_abi: #{message}")
    {:error, "internal error"}
  end

  # Whole seconds left, rounded up: below 1 only once the deadline passed.
  defp left_sec(deadline),
    do: div(deadline - System.monotonic_time(:millisecond) + 999, 1000)

  defp facts(system, version, work_dir, ctx, deadline) do
    with {:ok, project_dir} <- project(system, version, work_dir, ctx),
         env = WarmNerves.target_env(project_dir, system),
         :ok <- step(ctx, ["deps.get"], project_dir, env, deadline),
         :ok <- step(ctx, ["nerves.artifact.get"], project_dir, env, deadline),
         {:ok, dir} <- artifact(ctx.artifacts, system.name, version),
         {:ok, toolchain} <- toolchain(project_dir, system.name),
         {:ok, otp} <- otp(dir),
         {:ok, libs} <- libs(dir, ctx.lib_opts, deadline) do
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

  defp step(ctx, args, project_dir, env, deadline) do
    case left_sec(deadline) do
      left when left < 1 ->
        {:error, "timeout"}

      left ->
        case ctx.mix.(args, project_dir, env, ctx.log_file, left) do
          :ok -> :ok
          {:error, :timeout} -> {:error, "timeout"}
          {:error, {_code, output}} -> {:error, failure(args, output)}
        end
    end
  end

  defp failure(["deps.get"], output), do: deps_get_error(output)
  defp failure(args, _output), do: Enum.join(args, " ") <> " failed"

  # `mix args` under `timeout(1)` when the image has it (it signals the
  # process group, so what mix started dies too), its output appended to
  # `log_file` and its tail kept for `deps_get_error/1`. Literal mix tasks in
  # the generated project; log_file is under the /out mount.
  # sobelow_skip ["CI.System", "Traversal.FileModule"]
  defp run_mix(args, project_dir, env, log_file, timeout_sec) do
    {command, argv} =
      case System.find_executable("timeout") do
        nil -> {"mix", args}
        timeout -> {timeout, ["--kill-after=10", "#{timeout_sec}", "mix" | args]}
      end

    started = System.monotonic_time(:second)
    {output, code} = System.cmd(command, argv, cd: project_dir, env: env, stderr_to_stdout: true)
    _ = File.write(log_file, output, [:append])
    timed_out? = System.monotonic_time(:second) - started >= timeout_sec

    mix_outcome(code, command != "mix", timed_out?, tail(output))
  end

  defp mix_outcome(0, _bounded?, _timed_out?, _output), do: :ok
  defp mix_outcome(@timeout_exit, true, _timed_out?, _output), do: {:error, :timeout}
  defp mix_outcome(@killed_exit, true, true, _output), do: {:error, :timeout}
  defp mix_outcome(code, _bounded?, _timed_out?, output), do: {:error, {code, output}}

  defp tail(output) when byte_size(output) <= @output_tail_bytes, do: output

  defp tail(output),
    do: binary_part(output, byte_size(output) - @output_tail_bytes, @output_tail_bytes)

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
  defp libs(dir, lib_opts, deadline) do
    left = left_sec(deadline)

    lib_opts =
      Keyword.update(lib_opts, :timeout_sec, min(@extract_timeout_sec, left), &min(&1, left))

    cond do
      not File.regular?(Path.join([dir, "images", "rootfs.squashfs"])) ->
        {:error, "no rootfs"}

      left < 1 ->
        {:error, "timeout"}

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
