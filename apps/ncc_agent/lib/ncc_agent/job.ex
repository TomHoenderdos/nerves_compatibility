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

  The container gets `claim["input"]` as its `NCC_INPUT` unchanged: it is
  `Portal.Builder.worker_input/1`, what a local build gets. The worker lays
  out its own per-run Nerves cache farm over the read-only `/nerves-cache`
  (`NccWorker.NervesCache`); the agent only keeps the cache dir real
  (`NccAgent.NervesCache.prepare_cache/1`). After a `done` completion the
  portal's answer names the cache misses worth warming (`warm`), and
  `NccAgent.NervesCache.warm/4` runs them.

  A runner-side failure (a timeout, a failed pull, a crash, an upload of
  the run's files that still fails after its retries) completes the lease
  with exit code `20`, which the portal retries.

  `complete` carries `result.json`, `logs.tar.gz` (left out over 48 MiB)
  and the last 1 MiB of `runner.log`, which keeps the request within the
  portal's multipart limit however much the build printed.
  """

  require Logger

  alias Compatibility.Builder.Argv
  alias NccAgent.{Caps, Client, Config, Docker, Fs, Heartbeat, HexCache, NervesCache, Tar}

  @runner_failure 20
  @default_timeout_sec 7200
  @default_max_files 20_000
  @default_max_batch_bytes 536_870_912
  @default_max_file_bytes 268_435_456
  @default_max_total_bytes 2_147_483_648
  @sha ~r/\A[0-9a-f]{64}\z/
  @outcomes %{
    "done" => :done,
    "requeued" => :requeued,
    "failed" => :failed,
    "rejected" => :rejected
  }
  @complete_attempts 3
  # Each request of the upload (files/missing, every batch) gets this many
  # tries on a 5xx or a transport error.
  @upload_attempts 3
  @default_retry_ms 5_000

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

      # Nothing the container wrote is read while it may still be running:
      # it could swap a file for a symlink between an lstat and the read.
      if Docker.gone?(config, Argv.container_name(claim["run_id"])) do
        finish(req, claim, config, scratch, dirs, exit_code, hb)
      else
        Logger.error("job #{claim["run_id"]}: its container is still present; completing with 20")
        File.write!(runner_log, "[agent] container still present after the run\n", [:append])
        outcome(complete(req, lease_id, @runner_failure, nil))
      end
    rescue
      e ->
        Logger.error("job #{claim["run_id"]} crashed: #{Exception.message(e)}")
        outcome(complete(req, lease_id, @runner_failure, scratch))
    catch
      :exit, reason ->
        Logger.error("job #{claim["run_id"]} crashed: #{inspect(reason)}")
        outcome(complete(req, lease_id, @runner_failure, scratch))
    after
      Heartbeat.stop(hb)
      File.rm_rf(scratch)
    end
  end

  defp finish(req, claim, config, scratch, dirs, exit_code, hb) do
    lease_id = claim["lease_id"]
    exit_code = check_result(exit_code, dirs.out)
    Heartbeat.set_phase(hb, "uploading")
    exit_code = upload_or_fail(exit_code, req, lease_id, scratch, dirs.files, claim["upload"])

    case complete(req, lease_id, exit_code, scratch) do
      {:ok, :done, pairs} when exit_code == 0 ->
        warm(config, claim, pairs)
        {:ok, :done}

      other ->
        outcome(other)
    end
  end

  @doc """
  The `Compatibility.Builder.Argv` spec for `claim`: the agent's config and
  scratch dirs resolved the way `Portal.Builder.build_docker_args/4` resolves
  the local host's, with the Nerves cache read-only and never a build cache
  (a remote builder has none; `Portal.BuildCache.Promotion` is host-side).
  `NccAgent.ArgvParityTest` pins the result to the shared fixture. Pure.
  """
  @spec argv_spec(Config.t(), map(), dirs()) :: Argv.spec()
  def argv_spec(config, claim, dirs) do
    %{
      container_name: Argv.container_name(claim["run_id"]),
      user: config.build_user,
      image: image_ref(claim["image"]),
      cpus: config.cpus,
      memory: config.memory,
      build_concurrency: config.build_concurrency,
      nerves_cache_mode: :readonly,
      paths: %{
        work: dirs.work,
        out: dirs.out,
        files: dirs.files,
        tmp: dirs.tmp,
        cache: dirs.cache,
        nerves_cache: Config.path(config, :nerves_cache),
        hex_cache: Config.path(config, :hex_cache),
        build_cache: nil
      }
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
    NervesCache.prepare_cache(config)
    HexCache.prepare(config)

    write_input(claim, dirs.work)
    Fs.chown(config, Map.values(dirs), ["-R"])
    Fs.chown(config, [Config.path(config, :hex_cache)], [])

    spec = argv_spec(config, claim, dirs)
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

  # `claim["input"]` is `Portal.Builder.worker_input/1`, written as is.
  # sobelow_skip ["Traversal.FileModule"]
  defp write_input(claim, work_dir) do
    input = Map.get(claim, "input", %{})
    File.write!(Path.join(work_dir, "input.json"), Jason.encode_to_iodata!(input))
  end

  # A passing run whose files did not all reach the portal is not a pass:
  # `Portal.Catalog.Ingestion` skips an absent blob without a word, so the
  # run would be published without its precompiled files. Completing with
  # 20 has the portal retry the lease instead.
  defp upload_or_fail(0, req, lease_id, scratch, files_dir, caps) do
    case upload_files(req, lease_id, scratch, files_dir, caps) do
      :ok ->
        0

      :failed ->
        Logger.error("the files of #{lease_id} did not all upload: completing with 20")
        @runner_failure
    end
  end

  defp upload_or_fail(exit_code, _req, _lease_id, _scratch, _files_dir, _caps), do: exit_code

  # sobelow_skip ["Traversal.FileModule"]
  defp upload_files(req, lease_id, scratch, files_dir, caps) do
    caps = caps || %{}
    files = list_files(files_dir, caps)
    shas = Enum.map(files, &elem(&1, 0))

    with [_ | _] <- files,
         {:ok, missing} <-
           with_retry("files/missing", lease_id, fn -> Client.missing(req, lease_id, shas) end) do
      missing = MapSet.new(missing)
      upload_dir = Path.join(scratch, "upload")
      File.rm_rf!(upload_dir)
      File.mkdir!(upload_dir)

      files
      |> Enum.filter(fn {sha, _} -> MapSet.member?(missing, sha) end)
      |> Tar.batches(caps["max_batch_bytes"] || @default_max_batch_bytes)
      |> Enum.with_index()
      |> Enum.map(fn {batch, i} -> upload_batch(req, lease_id, upload_dir, batch, i) end)
      |> Enum.all?(&(&1 == :ok))
      |> if(do: :ok, else: :failed)
    else
      [] -> :ok
      {:error, _reason} -> :failed
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp upload_batch(req, lease_id, upload_dir, batch, i) do
    tar = Path.join(upload_dir, "batch-#{i}.tar")

    try do
      with :ok <- write_batch(batch, tar, i, lease_id) do
        send_batch(req, lease_id, tar, i)
      end
    after
      File.rm(tar)
    end
  end

  defp write_batch(batch, tar, i, lease_id) do
    case Tar.write(batch, tar) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("could not write batch #{i} of #{lease_id}: #{inspect(reason)}")
        :failed
    end
  end

  # A refusal of the content itself -- an entry that does not hash to its
  # name, or a batch over the portal's cap -- would be refused again on any
  # retry or attempt, so it is logged and the run goes on without those
  # files, as the portal's own size caps would have it. Anything else that
  # still fails after `with_retry/3` fails the upload.
  defp send_batch(req, lease_id, tar, i) do
    case with_retry("batch #{i}", lease_id, fn -> Client.upload(req, lease_id, tar) end) do
      {:ok, _} ->
        :ok

      {:error, {:bad_entries, bad}} ->
        Logger.error("the portal refused #{length(bad)} file(s) of #{lease_id}: #{inspect(bad)}")
        :ok

      {:error, {:http, 413, _}} ->
        Logger.error("the portal refused batch #{i} of #{lease_id} as too large")
        :ok

      {:error, _reason} ->
        :failed
    end
  end

  defp with_retry(what, lease_id, fun, attempt \\ 1) do
    case fun.() do
      {:error, reason} = error ->
        if attempt < @upload_attempts and retryable?(reason) do
          Logger.warning("#{what} for #{lease_id} failed (#{inspect(reason)}), retrying")
          Process.sleep(retry_ms() * attempt)
          with_retry(what, lease_id, fun, attempt + 1)
        else
          Logger.error("#{what} for #{lease_id} failed: #{inspect(reason)}")
          error
        end

      ok ->
        ok
    end
  end

  # Tests set `config :ncc_agent, retry_ms: 0`.
  defp retry_ms, do: Application.get_env(:ncc_agent, :retry_ms, @default_retry_ms)

  # The regular files named by a sha, in name order, within the claim's
  # caps: at most `max_files` of them, none over `max_file_bytes` (or over
  # what fits one batch), and no more than `max_total_bytes` together. The
  # sizes are the container's doing (a sparse file costs it nothing, and
  # `:erl_tar` would write it dense), so what is over a cap is left where it
  # is and logged rather than tarred and sent for the portal to refuse.
  # sobelow_skip ["Traversal.FileModule"]
  defp list_files(files_dir, caps) do
    max_files = caps["max_files"] || @default_max_files
    max_file = min(caps["max_file_bytes"] || @default_max_file_bytes, max_entry_bytes(caps))
    max_total = caps["max_total_bytes"] || @default_max_total_bytes

    with true <- regular?(files_dir, :directory),
         {:ok, names} <- File.ls(files_dir) do
      names
      |> Enum.sort()
      |> Enum.filter(&Regex.match?(@sha, &1))
      |> Enum.flat_map(&sized_regular(files_dir, &1))
      |> Enum.reject(fn {name, _path, size} -> oversized?(name, size, max_file) end)
      |> Enum.take(max_files)
      |> within_total(max_total)
    else
      _ -> []
    end
  end

  defp sized_regular(files_dir, name) do
    path = Path.join(files_dir, name)

    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} -> [{name, path, size}]
      _ -> []
    end
  end

  defp oversized?(name, size, max_file) do
    if size > max_file do
      Logger.warning("files/#{name} is #{size} bytes, over the #{max_file} cap: not uploaded")
      true
    else
      false
    end
  end

  # The largest content one batch can carry: the batch cap minus the tar's
  # own header and end-of-archive blocks.
  defp max_entry_bytes(caps) do
    max((caps["max_batch_bytes"] || @default_max_batch_bytes) - 3 * 512, 0)
  end

  defp within_total(files, max_total) do
    {kept, _total} =
      Enum.reduce_while(files, {[], 0}, fn {name, path, size}, {acc, total} ->
        if total + size <= max_total do
          {:cont, {[{name, path} | acc], total + size}}
        else
          Logger.warning(
            "files/#{name} would take the upload over #{max_total} bytes: stopping here"
          )

          {:halt, {acc, total}}
        end
      end)

    Enum.reverse(kept)
  end

  # `{:ok, outcome, warm}`: the portal's verdict on the attempt and, for a
  # `done` one, the Nerves cache pairs it wants warmed (`[]` otherwise).
  defp complete(req, lease_id, exit_code, scratch) do
    parts = if scratch, do: parts(scratch), else: %{}
    complete_with_retry(req, lease_id, exit_code, parts, 1)
  end

  defp outcome({:ok, outcome, _warm}), do: {:ok, outcome}
  defp outcome({:error, _reason} = error), do: error

  defp complete_with_retry(req, lease_id, exit_code, parts, attempt) do
    case Client.complete(req, lease_id, exit_code, parts) do
      {:ok, %{"outcome" => outcome} = body} when is_map_key(@outcomes, outcome) ->
        {:ok, Map.fetch!(@outcomes, outcome), Map.get(body, "warm", [])}

      {:ok, body} ->
        {:error, {:unexpected_complete, body}}

      {:error, reason} = error ->
        if attempt < @complete_attempts and retryable?(reason) do
          Logger.warning("complete for #{lease_id} failed (#{inspect(reason)}), retrying")
          Process.sleep(retry_ms() * attempt)
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
      result: if(result_ok?(result) == :ok, do: result),
      logs: logs_tarball(scratch, Path.join(out, "logs")),
      runner_log: runner_log_tail(scratch, runner_log)
    }
  end

  # The last `Caps.get(:runner_log_tail_bytes)` of `runner.log`, copied to a file of
  # its own: the heartbeat still reads the whole log.
  # sobelow_skip ["Traversal.FileModule"]
  defp runner_log_tail(scratch, runner_log) do
    tail = Path.join(scratch, "runner.tail.log")
    File.rm(tail)

    with {:ok, %File.Stat{type: :regular, size: size}} <- File.lstat(runner_log),
         {:ok, bytes} <- read_tail(runner_log, size),
         :ok <- File.write(tail, bytes) do
      tail
    else
      _ -> nil
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp read_tail(path, size) do
    offset = max(size - Caps.get(:runner_log_tail_bytes), 0)

    with {:ok, fd} <- :file.open(path, [:read, :binary, :raw]) do
      try do
        case :file.pread(fd, offset, size - offset) do
          {:ok, bytes} -> {:ok, bytes}
          :eof -> {:ok, ""}
          {:error, reason} -> {:error, reason}
        end
      after
        :file.close(fd)
      end
    end
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
          within_logs_cap(tar)

        {:error, reason} ->
          Logger.error("could not pack the logs: #{inspect(reason)}")
          nil
      end
    else
      _ -> nil
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp within_logs_cap(tar) do
    cap = Caps.get(:logs_tarball_bytes)

    case File.stat(tar) do
      {:ok, %File.Stat{size: size}} when size <= cap ->
        tar

      {:ok, %File.Stat{size: size}} ->
        Logger.warning("logs.tar.gz is #{size} bytes, over the #{cap} cap: not sent")

        File.rm(tar)
        nil

      {:error, _} ->
        nil
    end
  end

  # The logs to pack, in name order, each a regular `.log` file within
  # `log_bytes`, at most `max_logs` of them and `logs_total_bytes` together,
  # all measured by lstat before anything is read: a container can leave any
  # number of logs of any size, and gzip would otherwise read them all to
  # find out whether the tarball fits.
  defp logs(logs_dir, names) do
    cap = Caps.get(:log_bytes)
    max_logs = Caps.get(:max_logs)
    max_total = Caps.get(:logs_total_bytes)

    {logs, _count, _total} =
      names
      |> Enum.sort()
      |> Enum.filter(&String.ends_with?(&1, ".log"))
      |> Enum.reduce_while({[], 0, 0}, fn name, {acc, count, total} ->
        path = Path.join(logs_dir, name)

        case log_size(path, name, cap) do
          nil ->
            {:cont, {acc, count, total}}

          size when count + 1 > max_logs or total + size > max_total ->
            Logger.warning(
              "logs/#{name} is past the #{max_logs} logs / #{max_total} bytes cap: skipped"
            )

            {:halt, {acc, count, total}}

          size ->
            entry = {String.to_charlist(name), String.to_charlist(path)}
            {:cont, {[entry | acc], count + 1, total + size}}
        end
      end)

    Enum.reverse(logs)
  end

  defp log_size(path, name, cap) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size <= cap ->
        size

      {:ok, %File.Stat{type: :regular, size: size}} ->
        Logger.warning("logs/#{name} is #{size} bytes, over the #{cap} cap: skipped")
        nil

      _ ->
        nil
    end
  end

  # A passing run must leave a readable result.json within the cap;
  # otherwise the run is a runner failure (20), never a pass without one.
  defp check_result(0, out) do
    case result_ok?(Path.join(out, "result.json")) do
      :ok ->
        0

      {:error, :too_large} ->
        Logger.error("result.json too large (over #{Caps.get(:result_json_bytes)} bytes)")
        @runner_failure

      {:error, :missing} ->
        Logger.error("the worker exited 0 without a regular result.json")
        @runner_failure
    end
  end

  defp check_result(exit_code, _out), do: exit_code

  defp result_ok?(path) do
    cap = Caps.get(:result_json_bytes)

    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size <= cap -> :ok
      {:ok, %File.Stat{type: :regular}} -> {:error, :too_large}
      _ -> {:error, :missing}
    end
  end

  # The pairs are the portal's choice (`Portal.NervesCache.warm_pairs/2` over
  # the result.json this run uploaded); the agent only runs them.
  defp warm(config, claim, pairs) do
    warmed = NervesCache.warm(config, claim, pairs)

    if warmed not in [:ok, :skipped],
      do: Logger.warning("warming the Nerves cache failed: #{inspect(warmed)}")
  rescue
    e -> Logger.warning("warming the Nerves cache crashed: #{Exception.message(e)}")
  end

  defp regular?(path, type) do
    match?({:ok, %File.Stat{type: ^type}}, File.lstat(path))
  end
end
