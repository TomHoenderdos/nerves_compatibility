defmodule NccAgent.Job do
  @moduledoc """
  One claimed lease, start to finish: a scratch dir, the worker container
  run with the shared `Compatibility.Builder.Argv`, the upload of the files
  the portal lacks, `complete`, and the scratch dir removed whatever
  happened.

  The scratch dir is `<data>/scratch/<safe run_id>/` with the container's
  `work`, `out`, `files`, `tmp` and `cache` binds. Everything the agent
  writes itself (`runner.log`, upload batches, `logs.tar.gz`) stays outside
  those binds, and everything it reads back from them must be a regular
  file: the agent runs as root and the container could leave symlinks.

  A runner-side failure (a timeout, a failed pull, a crash) completes the
  lease with exit code `20`, which the portal retries.
  """

  require Logger

  alias Compatibility.Builder.Argv
  alias NccAgent.{Client, Config, Docker, Heartbeat, NervesCache, Tar}

  @runner_failure 20
  @default_timeout_sec 7200
  @default_max_files 20_000
  @default_max_batch_bytes 536_870_912
  @sha ~r/\A[0-9a-f]{64}\z/
  @outcomes %{
    "done" => :done,
    "requeued" => :requeued,
    "failed" => :failed,
    "rejected" => :rejected
  }
  @complete_attempts 3
  @complete_retry_ms 5_000

  @type outcome :: :done | :requeued | :failed | :rejected
  @type dirs :: %{
          work: Path.t(),
          out: Path.t(),
          files: Path.t(),
          tmp: Path.t(),
          cache: Path.t()
        }

  @doc "Runs `claim` to completion. The scratch dir is gone when it returns."
  @spec run(Req.Request.t(), map(), Config.t()) :: {:ok, outcome()} | {:error, term()}
  def run(req, claim, config) do
    lease_id = claim["lease_id"]

    case scratch_dir(config, claim["run_id"]) do
      {:ok, scratch} ->
        run_in(req, claim, config, scratch)

      :error ->
        Logger.error("lease #{lease_id} has an invalid run id #{inspect(claim["run_id"])}")
        complete(req, lease_id, @runner_failure, nil)
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp run_in(req, claim, config, scratch) do
    lease_id = claim["lease_id"]
    dirs = dirs(scratch)
    runner_log = Path.join(scratch, "runner.log")
    # A leftover of an earlier attempt that died without its cleanup.
    File.rm_rf(scratch)

    {:ok, hb} = Heartbeat.start_link(%{req: req, lease_id: lease_id, log_path: runner_log})

    try do
      exit_code = build(claim, config, dirs, runner_log, hb)
      Heartbeat.set_phase(hb, "uploading")
      if exit_code == 0, do: upload_files(req, lease_id, scratch, dirs.files, claim["upload"])
      outcome = complete(req, lease_id, exit_code, scratch)
      if exit_code == 0, do: warm(config, claim, dirs.out)
      outcome
    rescue
      e ->
        Logger.error("job #{claim["run_id"]} crashed: #{Exception.message(e)}")
        complete(req, lease_id, @runner_failure, scratch)
    catch
      :exit, reason ->
        Logger.error("job #{claim["run_id"]} crashed: #{inspect(reason)}")
        complete(req, lease_id, @runner_failure, scratch)
    after
      Heartbeat.stop(hb)
      File.rm_rf(scratch)
    end
  end

  @doc """
  The `Compatibility.Builder.Argv` spec for `claim`: the post-isolation
  argv, with the Nerves cache read-only at `/nerves-cache`, a read-only
  root with the scratch `tmp`/`cache` binds, and never a build cache. Pure.
  """
  @spec argv_spec(Config.t(), map(), dirs(), [{String.t(), String.t()}]) :: Argv.spec()
  def argv_spec(config, claim, dirs, env) do
    %{
      run_id: claim["run_id"],
      image: image_ref(claim["image"]),
      user: config.build_user,
      work_dir: dirs.work,
      output_dir: dirs.out,
      files_dir: dirs.files,
      nerves_cache: Config.path(config, :nerves_cache),
      hex_cache: Config.path(config, :hex_cache),
      build_cache: nil,
      cpus: config.cpus,
      memory: config.memory,
      build_concurrency: config.build_concurrency,
      nerves_cache_mode: :readonly,
      hardening: true,
      tmp_dir: dirs.tmp,
      cache_dir: dirs.cache,
      extra_env: env
    }
  end

  @doc "`name@digest` for a registry image, the bare name for a local one (`ncc-worker:local`)."
  @spec image_ref(map()) :: String.t()
  def image_ref(%{"name" => name, "digest" => digest}) when is_binary(name) do
    if String.contains?(name, "/"), do: "#{name}@#{digest}", else: name
  end

  defp scratch_dir(config, run_id) when is_binary(run_id) do
    {:ok, Path.join(Config.path(config, :scratch), Argv.safe_name(run_id))}
  rescue
    ArgumentError -> :error
  end

  defp scratch_dir(_config, _run_id), do: :error

  defp dirs(scratch) do
    %{
      work: Path.join(scratch, "work"),
      out: Path.join(scratch, "out"),
      files: Path.join(scratch, "files"),
      tmp: Path.join(scratch, "tmp"),
      cache: Path.join(scratch, "cache")
    }
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp build(claim, config, dirs, runner_log, hb) do
    Enum.each(Map.values(dirs), &File.mkdir_p!/1)
    File.mkdir_p!(Config.path(config, :nerves_cache))
    File.mkdir_p!(Config.path(config, :hex_cache))

    nerves = NervesCache.prepare(config, dirs.work)
    write_input(claim, dirs.work, nerves.env)
    chown(config, Map.values(dirs), ["-R"])
    chown(config, [Config.path(config, :hex_cache)], [])

    spec = argv_spec(config, claim, dirs, nerves.env)
    argv = Argv.build(spec)

    case ensure_image(config, spec.image, runner_log) do
      :ok ->
        Heartbeat.set_phase(hb, "building")
        run_container(claim, config, argv, runner_log)

      {:error, reason} ->
        Logger.error("job #{claim["run_id"]} could not pull #{spec.image}: #{reason}")
        File.write!(runner_log, "[agent] pull failed: #{reason}\n", [:append])
        @runner_failure
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp run_container(claim, config, argv, runner_log) do
    File.write!(runner_log, "[agent] docker #{Enum.join(argv, " ")}\n", [:append])
    timeout_ms = (claim["timeout_sec"] || @default_timeout_sec) * 1000

    case Docker.run(config, argv, runner_log, timeout_ms) do
      {:ok, exit_code} ->
        exit_code

      {:error, :timeout} ->
        Logger.error("job #{claim["run_id"]} timed out after #{div(timeout_ms, 1000)} s")
        @runner_failure

      {:error, reason} ->
        Logger.error("job #{claim["run_id"]} could not run docker: #{inspect(reason)}")
        @runner_failure
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp ensure_image(config, image, runner_log) do
    if Docker.present?(config, image) do
      :ok
    else
      File.write!(runner_log, "[agent] pulling #{image}\n", [:append])
      Docker.pull(config, image)
    end
  end

  # The worker of either generation finds the per-run Nerves dirs: newer
  # ones through `paths`, older ones through the container env.
  # sobelow_skip ["Traversal.FileModule"]
  defp write_input(claim, work_dir, env) do
    env = Map.new(env)

    input =
      claim
      |> Map.get("input", %{})
      |> Map.update("paths", %{}, & &1)
      |> update_in(["paths"], fn paths ->
        Map.merge(paths, %{
          "nerves_artifacts_dir" => env["NERVES_ARTIFACTS_DIR"],
          "nerves_dl_dir" => env["NERVES_DL_DIR"]
        })
      end)

    File.write!(Path.join(work_dir, "input.json"), Jason.encode_to_iodata!(input))
  end

  defp chown(config, paths, flags) do
    if config.build_user != Config.defaults().build_user do
      case System.cmd("chown", flags ++ [config.build_user | paths], stderr_to_stdout: true) do
        {_, 0} ->
          :ok

        {out, status} ->
          Logger.warning("chown #{config.build_user} exited #{status}: #{String.trim(out)}")
      end
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp upload_files(req, lease_id, scratch, files_dir, caps) do
    caps = caps || %{}
    files = list_files(files_dir, caps["max_files"] || @default_max_files)

    with [_ | _] <- files,
         {:ok, missing} <- Client.missing(req, lease_id, Enum.map(files, &elem(&1, 0))) do
      missing = MapSet.new(missing)
      upload_dir = Path.join(scratch, "upload")
      File.rm_rf!(upload_dir)
      File.mkdir!(upload_dir)

      files
      |> Enum.filter(fn {sha, _} -> MapSet.member?(missing, sha) end)
      |> Tar.batches(caps["max_batch_bytes"] || @default_max_batch_bytes)
      |> Enum.with_index()
      |> Enum.each(fn {batch, i} -> upload_batch(req, lease_id, upload_dir, batch, i) end)
    else
      [] ->
        :ok

      {:error, reason} ->
        Logger.error("files/missing for #{lease_id} failed: #{inspect(reason)}")
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp upload_batch(req, lease_id, upload_dir, batch, i) do
    tar = Path.join(upload_dir, "batch-#{i}.tar")

    try do
      :ok = Tar.write(batch, tar)

      case Client.upload(req, lease_id, tar) do
        {:ok, _} ->
          :ok

        {:error, {:bad_entries, bad}} ->
          Logger.error(
            "the portal refused #{length(bad)} file(s) of #{lease_id}: #{inspect(bad)}"
          )

        {:error, reason} ->
          Logger.error("uploading batch #{i} of #{lease_id} failed: #{inspect(reason)}")
      end
    after
      File.rm(tar)
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp list_files(files_dir, max_files) do
    with true <- regular?(files_dir, :directory),
         {:ok, names} <- File.ls(files_dir) do
      names
      |> Enum.sort()
      |> Enum.filter(&Regex.match?(@sha, &1))
      |> Enum.map(&{&1, Path.join(files_dir, &1)})
      |> Enum.filter(fn {_, path} -> regular?(path) end)
      |> Enum.take(max_files)
    else
      _ -> []
    end
  end

  defp complete(req, lease_id, exit_code, scratch) do
    parts = if scratch, do: parts(scratch), else: %{}
    complete_with_retry(req, lease_id, exit_code, parts, 1)
  end

  defp complete_with_retry(req, lease_id, exit_code, parts, attempt) do
    case Client.complete(req, lease_id, exit_code, parts) do
      {:ok, %{"outcome" => outcome}} when is_map_key(@outcomes, outcome) ->
        {:ok, Map.fetch!(@outcomes, outcome)}

      {:ok, body} ->
        {:error, {:unexpected_complete, body}}

      {:error, reason} = error ->
        if attempt < @complete_attempts and retryable?(reason) do
          Logger.warning("complete for #{lease_id} failed (#{inspect(reason)}), retrying")
          Process.sleep(@complete_retry_ms * attempt)
          complete_with_retry(req, lease_id, exit_code, parts, attempt + 1)
        else
          Logger.error("complete for #{lease_id} failed: #{inspect(reason)}")
          error
        end
    end
  end

  # A 5xx or a transport error (an exception struct) may pass on a retry;
  # a lease no longer held or a refused part will not.
  defp retryable?({:http, status, _}), do: status >= 500
  defp retryable?({:http, status}), do: status >= 500
  defp retryable?(%{__exception__: true}), do: true
  defp retryable?(_reason), do: false

  defp parts(scratch) do
    out = Path.join(scratch, "out")
    result = Path.join(out, "result.json")
    runner_log = Path.join(scratch, "runner.log")

    %{
      result: if(regular?(result), do: result),
      logs: logs_tarball(scratch, Path.join(out, "logs")),
      runner_log: if(regular?(runner_log), do: runner_log)
    }
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp logs_tarball(scratch, logs_dir) do
    with true <- regular?(logs_dir, :directory),
         {:ok, names} <- File.ls(logs_dir),
         [_ | _] = logs <- logs(logs_dir, names) do
      tar = Path.join(scratch, "logs.tar.gz")
      File.rm(tar)

      case :erl_tar.create(String.to_charlist(tar), logs, [:compressed]) do
        :ok ->
          tar

        {:error, reason} ->
          Logger.error("could not pack the logs: #{inspect(reason)}")
          nil
      end
    else
      _ -> nil
    end
  end

  defp logs(logs_dir, names) do
    for name <- Enum.sort(names),
        String.ends_with?(name, ".log"),
        path = Path.join(logs_dir, name),
        regular?(path),
        do: {String.to_charlist(name), String.to_charlist(path)}
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp warm(config, claim, out) do
    result =
      with true <- regular?(Path.join(out, "result.json")),
           {:ok, body} <- File.read(Path.join(out, "result.json")),
           {:ok, %{} = result} <- Jason.decode(body) do
        result
      else
        _ -> %{}
      end

    warmed = NervesCache.warm(config, claim, result)

    if warmed not in [:ok, :skipped],
      do: Logger.warning("warming the Nerves cache failed: #{inspect(warmed)}")
  rescue
    e -> Logger.warning("warming the Nerves cache crashed: #{Exception.message(e)}")
  end

  defp regular?(path, type \\ :regular) do
    match?({:ok, %File.Stat{type: ^type}}, File.lstat(path))
  end
end
