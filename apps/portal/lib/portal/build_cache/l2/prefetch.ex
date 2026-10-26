defmodule Portal.BuildCache.L2.Prefetch do
  @moduledoc """
  The download loop behind `Portal.BuildCache.L2.prefetch/3`: list the
  slug, pick the objects the local slug directory lacks, fetch them newest
  first under the budget, verify, extract and publish each. Why it syncs the
  listing, what it trusts and what it checks are in `Portal.BuildCache.L2`'s
  moduledoc.
  """
  require Logger
  alias Portal.BuildCache.L2.{Client, Config, Stats, Tarball}
  alias Portal.BuildCache.Staging

  @budget_bytes 2 * 1024 * 1024 * 1024
  @extracted_budget_bytes 4 * 1024 * 1024 * 1024
  @budget_ms :timer.minutes(5)
  @object_timeout_ms 120_000
  @key_pattern ~r/\A[0-9a-f]{64}\z/
  # Under this much time left a GET is not started: it would be cut short and
  # logged as a failure for nothing.
  @min_get_ms 1_000
  @max_failures_in_a_row 5
  # `:eacces` and `:eperm` from the extraction itself are the archive's
  # doing (modes it applied), so `{:tar, _}` leaves them out; see `classify/1`.
  @local_posix [
    :enospc,
    :eacces,
    :eio,
    :enoent,
    :erofs,
    :emfile,
    :enfile,
    :edquot,
    :eperm,
    :enotdir
  ]

  @doc """
  The wall-clock budget of one build's prefetch. Exposed so the Oban config
  test can keep `Lifeline`'s `rescue_after` above a build's whole worst case.
  """
  @spec budget_ms() :: pos_integer()
  def budget_ms, do: @budget_ms

  @doc false
  @spec empty_counts() :: map()
  def empty_counts do
    %{
      listed: 0,
      candidates: 0,
      downloaded: 0,
      discarded: 0,
      failed: 0,
      skipped: 0,
      bytes: 0,
      extracted_bytes: 0,
      list_failed: false
    }
  end

  @doc "Runs the sync for `Portal.BuildCache.L2.prefetch/3` with a resolved config."
  @spec run(Config.t(), Path.t(), String.t(), keyword()) :: map()
  def run(cfg, slug_dir, slug, opts) do
    prefix = slug <> "/"
    # The listing spends the same budget as the downloads: up to 50 pages,
    # each with its own receive timeout, would otherwise hold the build long
    # before the first GET.
    deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :budget_ms, @budget_ms)

    case bounded_list(cfg, prefix, deadline) do
      {:ok, objects} ->
        max_object = Keyword.get(opts, :max_object_bytes, Tarball.max_object_bytes())
        candidates = candidates(objects, prefix, local_names(slug_dir), max_object)

        budget = %{
          bytes: Keyword.get(opts, :budget_bytes, @budget_bytes),
          extracted: Keyword.get(opts, :extracted_budget_bytes, @extracted_budget_bytes),
          deadline: deadline,
          free_bytes: Keyword.get(opts, :free_bytes, &Portal.Builder.free_bytes/1),
          min_free:
            Keyword.get_lazy(opts, :min_free_bytes, &Portal.Builder.prefetch_min_free_bytes/0)
        }

        counts = %{empty_counts() | listed: length(objects), candidates: length(candidates)}

        candidates
        |> Enum.reduce({counts, {:go, 0}}, &fetch_candidate(&1, &2, cfg, slug_dir, budget))
        |> elem(0)

      {:error, reason} ->
        Stats.record(:list_failed)

        Logger.warning(
          "Build cache L2 listing of #{prefix} failed: #{inspect(reason, printable_limit: 200)}"
        )

        %{empty_counts() | list_failed: true}
    end
  end

  # The same shape as `Client.get/4`: a task killed at the deadline, and
  # nothing inside it can take the caller down.
  defp bounded_list(cfg, prefix, deadline) do
    task =
      Task.async(fn ->
        try do
          Client.list(cfg, prefix)
        catch
          kind, reason -> {:error, Client.caught(kind, reason)}
        end
      end)

    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, {:exit, reason}}
      nil -> {:error, :timeout}
    end
  end

  defp candidates(objects, prefix, local, max_object) do
    objects
    |> Enum.flat_map(fn obj ->
      hex = object_hex(obj.key, prefix)

      if hex && obj.size <= max_object && not MapSet.member?(local, hex) && not Stats.bad?(hex),
        do: [{hex, obj}],
        else: []
    end)
    |> Enum.sort_by(fn {_hex, obj} -> obj.last_modified end, {:desc, DateTime})
  end

  defp object_hex(key, prefix) do
    with ^prefix <> rest <- key,
         [hex, ""] <- String.split(rest, ".tar.gz", parts: 2),
         true <- Regex.match?(@key_pattern, hex) do
      hex
    else
      _ -> nil
    end
  end

  # `slug_dir` is the per-image directory under the operator's cache root.
  # sobelow_skip ["Traversal.FileModule"]
  defp local_names(slug_dir) do
    case File.ls(slug_dir) do
      {:ok, names} -> MapSet.new(names)
      {:error, _} -> MapSet.new()
    end
  end

  # `state` is `{:go, failures_in_a_row}` or `:stop`.
  defp fetch_candidate({hex, obj}, {counts, state}, cfg, slug_dir, budget) do
    remaining_ms = budget.deadline - System.monotonic_time(:millisecond)

    cond do
      state == :stop or remaining_ms < @min_get_ms or counts.bytes + obj.size > budget.bytes ->
        {bump(counts, :skipped), state}

      low_disk?(slug_dir, budget) ->
        {bump(counts, :skipped), :stop}

      not Stats.claim(hex) ->
        {bump(counts, :skipped), state}

      true ->
        try do
          cfg
          |> download_one(slug_dir, hex, obj, budget.deadline)
          |> tally(counts, state)
          |> charge_extracted(budget)
        after
          Stats.release(hex)
        end
    end
  end

  # Before every object: the downloads and their extracted trees land on the
  # cache filesystem, which may not be scratch's. A filesystem `df` cannot
  # measure is not refused. Logged once, since it stops the loop.
  defp low_disk?(slug_dir, budget) do
    case budget.free_bytes.(slug_dir) do
      free when is_integer(free) and free < budget.min_free ->
        Logger.warning(
          "Build cache L2 prefetch into #{slug_dir} stopped: #{free} bytes free, " <>
            "under the #{budget.min_free} bytes kept free"
        )

        true

      _ ->
        false
    end
  end

  # Extraction is charged with the pre-scan's decompressed size; once the
  # build has extracted its budget the remaining objects are skipped.
  defp charge_extracted({counts, state}, budget) do
    if counts.extracted_bytes >= budget.extracted do
      Logger.info(
        "Build cache L2 prefetch stopped: #{counts.extracted_bytes} bytes extracted, " <>
          "the per-build budget is #{budget.extracted}"
      )

      {counts, :stop}
    else
      {counts, state}
    end
  end

  defp tally({:ok, bytes, extracted}, counts, _state) do
    Stats.record(:download_ok, bytes)

    {%{
       bump(counts, :downloaded)
       | bytes: counts.bytes + bytes,
         extracted_bytes: counts.extracted_bytes + extracted
     }, {:go, 0}}
  end

  defp tally({:discarded, bytes, extracted}, counts, _state) do
    Stats.record(:discarded)

    {%{
       bump(counts, :discarded)
       | bytes: counts.bytes + bytes,
         extracted_bytes: counts.extracted_bytes + extracted
     }, {:go, 0}}
  end

  defp tally({:error, {:refused, _}}, counts, state), do: {bump(counts, :failed), state}
  defp tally({:error, {:failed, :stop}}, counts, _state), do: {bump(counts, :failed), :stop}

  defp tally({:error, {:failed, :go}}, counts, {:go, streak}) do
    {bump(counts, :failed),
     if(streak + 1 >= @max_failures_in_a_row, do: :stop, else: {:go, streak + 1})}
  end

  defp bump(counts, field), do: Map.update!(counts, field, &(&1 + 1))

  # One object: GET into a staging tarball, verify, extract into a staging
  # dir beside the entry, publish by rename unless the entry arrived
  # meanwhile. Both staging names are removed whatever happened.
  # `slug_dir` is the per-image directory under the operator's cache root and
  # `hex` a validated 64-hex key, so every path here is host-built.
  # sobelow_skip ["Traversal.FileModule"]
  defp download_one(cfg, slug_dir, hex, obj, deadline) do
    dest = Path.join(slug_dir, hex)
    staging = Staging.name(dest)
    tar = staging <> ".tar.gz"

    result =
      try do
        fetch_and_publish(cfg, obj, tar, staging, dest, deadline)
      after
        _ = File.rm(tar)
        _ = File.rm_rf(staging)
      end

    case result do
      {:error, reason} -> failed(obj.key, hex, reason)
      done -> done
    end
  end

  # Staging names built by `download_one/5`. The GET and the extraction
  # each get what is left of the build's budget, at most 120 s.
  # sobelow_skip ["Traversal.FileModule"]
  defp fetch_and_publish(cfg, obj, tar, staging, dest, deadline) do
    with {:ok, %{bytes: bytes} = got} <- get(cfg, obj, tar, deadline),
         :ok <- verify_sha(got),
         :ok <- File.mkdir(staging),
         {:ok, %{extracted_bytes: extracted}} <- unpack(tar, staging, deadline) do
      _ = File.rm(tar)

      case publish(staging, dest) do
        :ok -> {:ok, bytes, extracted}
        :discarded -> {:discarded, bytes, extracted}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # A body longer than the listing said means the object was replaced after
  # the listing, not that it is wrong: a plain failure, not a refusal.
  defp get(cfg, obj, tar, deadline) do
    case Client.get(cfg, obj.key, tar, max_bytes: obj.size, timeout_ms: object_timeout(deadline)) do
      {:error, :too_large} -> {:error, :larger_than_listed}
      other -> other
    end
  end

  # An extraction that runs out of time is the archive's fault only when it
  # had the full per-object time; cut short by the build's budget, it is the
  # budget that ran out, and the object is not marked bad for it.
  defp unpack(tar, staging, deadline) do
    timeout = object_timeout(deadline)

    case Tarball.unpack(tar, staging, timeout_ms: timeout) do
      {:error, {:unpack, :timeout}} when timeout < @object_timeout_ms -> {:error, :budget_spent}
      other -> other
    end
  end

  defp object_timeout(deadline),
    do:
      deadline
      |> Kernel.-(System.monotonic_time(:millisecond))
      |> max(0)
      |> min(@object_timeout_ms)

  defp verify_sha(%{sha256_header: nil}), do: {:error, :no_sha256_header}

  defp verify_sha(%{sha256_computed: computed, sha256_header: header}) do
    if computed == String.downcase(header),
      do: :ok,
      else: {:error, {:sha256_mismatch, computed, header}}
  end

  # An entry that exists by now (a local promotion, another node on a shared
  # root) wins; rename(2) refuses a non-empty directory, which closes the
  # window between the lstat and the rename.
  # sobelow_skip ["Traversal.FileModule"]
  defp publish(staging, dest) do
    case File.lstat(dest) do
      {:ok, _} -> :discarded
      {:error, :enoent} -> rename(staging, dest)
      {:error, reason} -> {:error, {:lstat, reason}}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp rename(staging, dest) do
    case File.rename(staging, dest) do
      :ok -> :ok
      {:error, reason} when reason in [:eexist, :enotempty] -> :discarded
      {:error, reason} -> {:error, {:rename, reason}}
    end
  end

  # A refused object is marked bad so this node does not fetch it again for
  # a day; a failed transfer is only counted.
  defp failed(object, hex, reason) do
    {kind, _} = class = classify(reason)

    if kind == :refused do
      Stats.mark_bad(hex)
      Stats.record(:refused)
    else
      Stats.record(:download_failed)
    end

    Logger.warning(
      "Build cache L2 download of #{object} failed: #{inspect(reason, printable_limit: 200)}"
    )

    {:error, class}
  end

  @doc """
  How a download failure is handled: `:refused` when the object itself is
  wrong (marked bad for a day), `:failed` otherwise; `:stop` when the store
  is failing and the loop should end for this build. Local I/O errors during
  extraction are this host's problem, never the object's, except a refused
  permission while extracting (`{:tar, :eacces | :eperm}`), which comes from
  modes the archive applied. An extraction the bound killed or timed out
  (`{:unpack, _}`) is the archive's doing; one cut short by the build's own
  budget (`:budget_spent`) is not. A body longer than the listing said
  (`:larger_than_listed`) is an object replaced after the listing.
  """
  @spec classify(term()) :: {:refused | :failed, :stop | :go}
  def classify(reason) do
    cond do
      local_io?(reason) -> {:failed, :go}
      refusal?(reason) -> {:refused, :go}
      store_failing?(reason) -> {:failed, :stop}
      true -> {:failed, :go}
    end
  end

  defp local_io?({:tar, posix}) when posix in [:eacces, :eperm], do: false
  defp local_io?({tag, posix}) when tag in [:tar, :links], do: posix in @local_posix
  defp local_io?(_), do: false

  defp refusal?(reason)
       when reason in [:no_sha256_header, :too_large, :empty_archive, :empty, :empty_entry],
       do: true

  defp refusal?({tag, _})
       when tag in [:tar, :structure, :member_name, :links, :gzip, :unpack],
       do: true

  defp refusal?({tag, _, _}) when tag in [:sha256_mismatch, :member_type], do: true
  defp refusal?(_), do: false

  defp store_failing?(reason) when reason in [:timeout, :budget_spent], do: true
  defp store_failing?({:status, status}) when status in [401, 403] or status >= 500, do: true
  defp store_failing?({tag, _}) when tag in [:exit, :exception, :throw], do: true
  defp store_failing?(%Req.TransportError{}), do: true
  defp store_failing?(%Mint.TransportError{}), do: true
  defp store_failing?(_), do: false
end
