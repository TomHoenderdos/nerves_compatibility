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
  @budget_ms :timer.minutes(5)
  @object_timeout_ms 120_000
  @key_pattern ~r/\A[0-9a-f]{64}\z/

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
      list_failed: false
    }
  end

  @doc "Runs the sync for `Portal.BuildCache.L2.prefetch/3` with a resolved config."
  @spec run(Config.t(), Path.t(), String.t(), keyword()) :: map()
  def run(cfg, slug_dir, slug, opts) do
    prefix = slug <> "/"

    case Client.list(cfg, prefix) do
      {:ok, objects} ->
        max_object = Keyword.get(opts, :max_object_bytes, Tarball.max_object_bytes())
        candidates = candidates(objects, prefix, local_names(slug_dir), max_object)
        now = System.monotonic_time(:millisecond)

        budget = %{
          bytes: Keyword.get(opts, :budget_bytes, @budget_bytes),
          deadline: now + Keyword.get(opts, :budget_ms, @budget_ms)
        }

        counts = %{empty_counts() | listed: length(objects), candidates: length(candidates)}

        candidates
        |> Enum.reduce({counts, :go}, &fetch_candidate(&1, &2, cfg, slug_dir, budget))
        |> elem(0)

      {:error, reason} ->
        Stats.record(:list_failed)

        Logger.warning(
          "Build cache L2 listing of #{prefix} failed: #{inspect(reason, printable_limit: 200)}"
        )

        %{empty_counts() | list_failed: true}
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

  defp fetch_candidate({hex, obj}, {counts, state}, cfg, slug_dir, budget) do
    remaining_ms = budget.deadline - System.monotonic_time(:millisecond)

    cond do
      state == :stop or remaining_ms <= 0 or counts.bytes + obj.size > budget.bytes ->
        {bump(counts, :skipped), state}

      not Stats.claim(hex) ->
        {bump(counts, :skipped), state}

      true ->
        try do
          cfg
          |> download_one(slug_dir, hex, obj, min(remaining_ms, @object_timeout_ms))
          |> tally(counts)
        after
          Stats.release(hex)
        end
    end
  end

  defp tally({:ok, bytes}, counts) do
    Stats.record(:download_ok, bytes)
    {%{bump(counts, :downloaded) | bytes: counts.bytes + bytes}, :go}
  end

  defp tally({:discarded, bytes}, counts) do
    Stats.record(:discarded)
    {%{bump(counts, :discarded) | bytes: counts.bytes + bytes}, :go}
  end

  defp tally({:error, :stop}, counts), do: {bump(counts, :failed), :stop}
  defp tally({:error, _}, counts), do: {bump(counts, :failed), :go}

  defp bump(counts, field), do: Map.update!(counts, field, &(&1 + 1))

  # One object: GET into a staging tarball, verify, extract into a staging
  # dir beside the entry, publish by rename unless the entry arrived
  # meanwhile. Both staging names are removed whatever happened.
  # `slug_dir` is the per-image directory under the operator's cache root and
  # `hex` a validated 64-hex key, so every path here is host-built.
  # sobelow_skip ["Traversal.FileModule"]
  defp download_one(cfg, slug_dir, hex, obj, timeout_ms) do
    dest = Path.join(slug_dir, hex)
    staging = Staging.name(dest)
    tar = staging <> ".tar.gz"

    result =
      try do
        fetch_and_publish(cfg, obj, tar, staging, dest, timeout_ms)
      after
        _ = File.rm(tar)
        _ = File.rm_rf(staging)
      end

    case result do
      {:error, reason} -> failed(obj.key, hex, reason)
      done -> done
    end
  end

  # Staging names built by `download_one/5`.
  # sobelow_skip ["Traversal.FileModule"]
  defp fetch_and_publish(cfg, obj, tar, staging, dest, timeout_ms) do
    with {:ok, %{bytes: bytes} = got} <-
           Client.get(cfg, obj.key, tar, max_bytes: obj.size, timeout_ms: timeout_ms),
         :ok <- verify_sha(got),
         :ok <- File.mkdir(staging),
         :ok <- Tarball.unpack(tar, staging) do
      _ = File.rm(tar)

      case publish(staging, dest) do
        :ok -> {:ok, bytes}
        :discarded -> {:discarded, bytes}
        {:error, reason} -> {:error, reason}
      end
    end
  end

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
  # a day; a failed transfer is only counted. A timeout or a transport error
  # ends the loop for this build.
  defp failed(object, hex, reason) do
    if verification_failure?(reason) do
      Stats.mark_bad(hex)
      Stats.record(:refused)
    else
      Stats.record(:download_failed)
    end

    Logger.warning(
      "Build cache L2 download of #{object} failed: #{inspect(reason, printable_limit: 200)}"
    )

    if stop?(reason), do: {:error, :stop}, else: {:error, reason}
  end

  defp verification_failure?(reason)
       when reason in [:no_sha256_header, :too_large, :empty_archive],
       do: true

  defp verification_failure?({tag, _}) when tag in [:tar, :structure, :member_name, :links],
    do: true

  defp verification_failure?({tag, _, _}) when tag in [:sha256_mismatch, :member_type], do: true
  defp verification_failure?(_), do: false

  defp stop?(:timeout), do: true
  defp stop?(%Req.TransportError{}), do: true
  defp stop?(%Mint.TransportError{}), do: true
  defp stop?(_), do: false
end
