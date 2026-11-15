defmodule Portal.Precompiled.FirmwareBuildPathWithdrawal do
  @moduledoc """
  Counts, then withdraws, served firmware results whose beams hold the
  builder's build tree, from before the worker judged firmware builds by the
  baked build path rule (`NccWorker.FirmwareBuildRoot`). A beam that keeps
  `/work/proj/deps_<target>/<dep>/lib` (xla's `checksum_path/0`,
  `Path.expand("../checksum.txt", __DIR__)`) points at a tree that exists
  only on the builder. Nothing runs this on its own: no job and no schedule
  calls it. The operator counts, reads the list, and acts.

  ## What is withdrawn

  A served firmware result (a passing target other than `host` and
  `pure_elixir`, with files, not withdrawn) is a candidate when its package
  version has an unrevoked, traced toolchain build (any toolchain or
  optional-dependency variant, the default config variant) refused as `bakes the build path: ` at
  `Compatibility.Portability.withdrawal_judge_revision/0` or later. That
  refusal is the host judge's R2 verdict on the same source, the rule the
  worker now applies to firmware builds too. The portal cannot rerun that
  rule (it needs the build's source tree), so it confirms on the result's
  own files instead: a candidate is withdrawn only when one of its `ebin`
  files (its own build's and every published variant's) holds a builder root
  (`roots/0`) in a beam's string, atom or literal table (a compressed
  literal table and a gzipped beam are inflated, at most 64 MiB) or anywhere
  in a `.app`. The metadata chunks (`CInf`, `Dbgi`, `Docs`, `Line`) and the
  attribute chunk (`@external_resource`) are not read.

  A candidate whose files hold no root is listed as `clean`, and one with a
  blob this host lacks or cannot read as `unreadable`; neither is withdrawn,
  both are for a hand check.

  Each result is judged on its own files, so every older run's result and
  every carried copy (`carried_from_run_id`) that serves the same files is a
  candidate of its own. A blob is read once per call.

  ## Safety

    * `withdraw/1` counts unless given `dry_run: false`;
    * one call reads at most `max_bytes:` of blobs (default 64 MiB; the first
      result of a call is always read whole) and withdraws at most `limit:`
      results (default 100); it returns `next:`, the last result it judged,
      for the next call's `after:` (`nil` once the candidates ran out);
    * it is idempotent: a withdrawn result is no longer a candidate, and one
      withdrawn some other way keeps its own `unpublished_at`;
    * every result one call withdraws carries the same `unpublished_at`
      (`withdrawn_at`, listed by `withdrawals/0`) and `unpublished_reason`
      `SystemResult.baked_build_path/0`; `undo/1` puts back exactly the
      results with that timestamp and reason, never another tool's.

  A firmware run made after the worker rule shipped withholds such a build at
  the source: its result has no files and is never a candidate.

  ## Operator commands (web host)

      bin/portal rpc 'Portal.Precompiled.FirmwareBuildPathWithdrawal.withdraw() |> IO.inspect(limit: :infinity)'
      bin/portal rpc 'Portal.Precompiled.FirmwareBuildPathWithdrawal.withdraw(after: "<next>") |> IO.inspect(limit: :infinity)'
      bin/portal rpc 'Portal.Precompiled.FirmwareBuildPathWithdrawal.withdraw(dry_run: false, limit: 100) |> IO.inspect(limit: :infinity)'
      bin/portal rpc 'Portal.Precompiled.FirmwareBuildPathWithdrawal.withdrawals() |> IO.inspect(limit: :infinity)'
      bin/portal rpc 'Portal.Precompiled.FirmwareBuildPathWithdrawal.undo(~U[2026-11-16 12:00:00.000000Z]) |> IO.inspect()'

  Count first, following `next:` until it is `nil`; then act, repeating the
  third (with `after:` while `next:` is set) until it withdraws nothing.
  """

  require Logger

  alias Compatibility.Portability
  alias Portal.ArtifactStore
  alias Portal.Catalog.SystemResult
  alias Portal.Repo

  @default_limit 100
  @default_max_bytes 64 * 1024 * 1024
  @max_blob 64 * 1024 * 1024
  @page 200
  @refusal "bakes the build path: "
  @roots ["/work/proj/", "/home/nerves/"]
  @chunks ~w(StrT AtU8 Atom LitT)

  # `$1` the cursor (a result id, null: from the start), `$2` the page size.
  # `t` is the version's refusal, the newest first, in the default config
  # variant: a firmware build is made in the default config, and a named
  # config variant's verdict says nothing about it.
  @candidates_sql """
  SELECT s.id, s.system_pkg, p.name, r.version_tested,
         s.beam_scan->'footprint'->'file_manifest', s.published_variants, ref.reason
  FROM catalog_system_results s
  JOIN catalog_runs r ON r.id = s.run_id
  JOIN catalog_packages p ON p.id = r.package_id
  CROSS JOIN LATERAL (
    SELECT t.reason
    FROM catalog_toolchain_builds t
    WHERE t.package_id = r.package_id
      AND t.version = r.version_tested
      AND t.config_variant = 'default'
      AND t.status = 'skipped'
      AND t.revoked_at IS NULL
      AND t.compile_observations IS NOT NULL
      AND t.judge_revision >= #{Portability.withdrawal_judge_revision()}
      AND starts_with(t.reason, '#{@refusal}')
    ORDER BY t.finished_at DESC NULLS LAST, t.id
    LIMIT 1
  ) ref
  WHERE s.system_pkg NOT IN ('host', 'pure_elixir')
    AND s.status = 'pass'
    AND s.unpublished_at IS NULL
    AND ($1::uuid IS NULL OR s.id > $1::uuid)
    AND EXISTS (SELECT 1 FROM catalog_artifact_memberships m WHERE m.system_result_id = s.id)
  ORDER BY s.id
  LIMIT $2
  """

  @withdraw_sql """
  UPDATE catalog_system_results
  SET unpublished_at = $2, unpublished_reason = $3, updated_at = $2
  WHERE id = ANY($1::uuid[]) AND unpublished_at IS NULL
  """

  @withdrawals_sql """
  SELECT s.unpublished_at, count(*),
         array_agg(DISTINCT p.name || ' ' || r.version_tested || ' ' || s.system_pkg)
  FROM catalog_system_results s
  JOIN catalog_runs r ON r.id = s.run_id
  JOIN catalog_packages p ON p.id = r.package_id
  WHERE s.unpublished_reason = $1 AND s.unpublished_at IS NOT NULL
  GROUP BY s.unpublished_at
  ORDER BY s.unpublished_at
  """

  @undo_sql """
  UPDATE catalog_system_results
  SET unpublished_at = NULL, unpublished_reason = NULL, updated_at = now() AT TIME ZONE 'utc'
  WHERE unpublished_reason = $1 AND unpublished_at = $2
  """

  @type row :: %{
          id: String.t(),
          package: String.t(),
          version: String.t(),
          system_pkg: String.t(),
          reason: String.t(),
          holder: String.t() | nil
        }

  @type report :: %{
          confirmed: [row()],
          clean: [row()],
          unreadable: [row()],
          bytes_read: non_neg_integer(),
          next: String.t() | nil
        }

  @doc "The byte strings a builder's build tree starts with, which `withdraw/1` looks for."
  @spec roots() :: [String.t()]
  def roots, do: @roots

  @doc """
  Counts (the default) or withdraws the candidates.

  Options: `dry_run:` (`true`), `limit:` (#{@default_limit}, the most results
  one call withdraws), `max_bytes:` (#{@default_max_bytes}, the blob bytes
  one call reads), `after:` (a result id, the previous call's `next:`).

  Returns `{:dry_run, report}`, where `confirmed` lists what acting would
  withdraw, or `{:withdrawn, count, report}`, where `confirmed` lists what
  this call withdrew and the report adds `withdrawn_at`, the value `undo/1`
  takes (nil when nothing was withdrawn).
  """
  @spec withdraw(keyword()) ::
          {:dry_run, report()} | {:withdrawn, non_neg_integer(), map()}
  def withdraw(opts \\ []) do
    limit = positive!(opts, :limit, @default_limit)
    max_bytes = positive!(opts, :max_bytes, @default_max_bytes)
    cursor = cursor!(Keyword.get(opts, :after))
    report = scan(cursor, limit, max_bytes)

    if Keyword.get(opts, :dry_run, true),
      do: {:dry_run, report},
      else: act(report)
  end

  @doc """
  Every withdrawal this module made, grouped by its `unpublished_at`:
  `%{withdrawn_at, results, versions}`, oldest first, `versions` as
  `"<package> <version> <system>"`.
  """
  @spec withdrawals() :: [
          %{withdrawn_at: DateTime.t(), results: pos_integer(), versions: [String.t()]}
        ]
  def withdrawals do
    %{rows: rows} = Repo.query!(@withdrawals_sql, [SystemResult.baked_build_path()])

    Enum.map(rows, fn [at, count, versions] ->
      %{withdrawn_at: to_utc(at), results: count, versions: Enum.sort(versions)}
    end)
  end

  @doc """
  Puts back the results this module withdrew at `withdrawn_at` (its
  `unpublished_reason` and exactly that `unpublished_at`). Returns how many.
  """
  @spec undo(DateTime.t() | NaiveDateTime.t()) :: {:restored, non_neg_integer()}
  def undo(%DateTime{} = withdrawn_at), do: withdrawn_at |> naive_utc() |> undo()

  def undo(%NaiveDateTime{} = withdrawn_at) do
    %{num_rows: count} =
      Repo.query!(@undo_sql, [SystemResult.baked_build_path(), withdrawn_at])

    Logger.warning("restored #{count} firmware publications withdrawn at #{withdrawn_at}")
    {:restored, count}
  end

  @doc """
  What one file's bytes say: `:hit` when a root is in a beam's string, atom
  or literal table, or anywhere in a non-beam file (a `.app`), `:clean`
  when not, `{:error, why}` when a beam cannot be read. Public for tests.
  """
  @spec holds_root?(binary()) :: :hit | :clean | {:error, String.t()}
  def holds_root?(<<31, 139, _::binary>> = gz) do
    case inflate(gz, 31, @max_blob) do
      {:ok, <<"FOR1", _::binary>> = beam} -> holds_root?(beam)
      {:ok, _other} -> {:error, "gzipped file is not a beam"}
      {:error, _} = error -> error
    end
  end

  def holds_root?(<<"FOR1", _size::32, "BEAM", body::binary>>) do
    with {:ok, chunks} <- chunks(body, []) do
      Enum.reduce_while(chunks, :clean, fn {id, data}, :clean -> chunk_verdict(id, data) end)
    end
  end

  def holds_root?(<<"FOR1", _::binary>>), do: {:error, "not a beam container"}

  def holds_root?(bytes) when is_binary(bytes), do: if(hit?(bytes), do: :hit, else: :clean)

  defp chunk_verdict(id, data) do
    case chunk_data(id, data) do
      {:ok, bytes} -> if hit?(bytes), do: {:halt, :hit}, else: {:cont, :clean}
      {:error, _} = error -> {:halt, error}
    end
  end

  # One page of candidates at a time, in id order, until the budget, the
  # limit or the candidates run out.
  defp scan(cursor, limit, max_bytes) do
    state = %{
      confirmed: [],
      clean: [],
      unreadable: [],
      bytes_read: 0,
      next: nil,
      cache: %{},
      max_bytes: max_bytes,
      limit: limit,
      first?: true
    }

    state = pages(cursor, state)

    %{
      confirmed: Enum.reverse(state.confirmed),
      clean: Enum.reverse(state.clean),
      unreadable: Enum.reverse(state.unreadable),
      bytes_read: state.bytes_read,
      next: state.next
    }
  end

  defp pages(cursor, state) do
    %{rows: rows} = Repo.query!(@candidates_sql, [dump(cursor), @page])

    case judge_rows(Enum.map(rows, &row/1), state) do
      {:stopped, state} -> state
      {:done, state} when length(rows) < @page -> %{state | next: nil}
      {:done, state} -> pages(state.next, state)
    end
  end

  defp judge_rows([], state), do: {:done, state}

  defp judge_rows([row | rest], state) do
    cond do
      length(state.confirmed) >= state.limit ->
        {:stopped, state}

      not state.first? and state.bytes_read + unread_bytes(row, state) > state.max_bytes ->
        {:stopped, state}

      true ->
        judge_rows(rest, judge_row(row, %{state | first?: false}))
    end
  end

  defp judge_row(row, state) do
    {outcome, state} =
      Enum.reduce_while(row.files, {:clean, state}, fn file, {_, state} ->
        case blob(file, state) do
          {:hit, state} -> {:halt, {{:hit, file["path"]}, state}}
          {:clean, state} -> {:cont, {:clean, state}}
          {:error, state} -> {:halt, {:unreadable, state}}
        end
      end)

    public = Map.drop(row, [:files])
    state = %{state | next: row.id}

    case outcome do
      {:hit, path} -> %{state | confirmed: [%{public | holder: path} | state.confirmed]}
      :clean -> %{state | clean: [public | state.clean]}
      :unreadable -> %{state | unreadable: [public | state.unreadable]}
    end
  end

  # A blob's verdict, read at most once per call.
  defp blob(%{"sha256" => sha}, state) when is_binary(sha) do
    case Map.fetch(state.cache, sha) do
      {:ok, verdict} ->
        {verdict, state}

      :error ->
        {verdict, size} = read_blob(sha)

        {verdict,
         %{state | cache: Map.put(state.cache, sha, verdict), bytes_read: state.bytes_read + size}}
    end
  end

  defp blob(_file, state), do: {:error, state}

  # sobelow_skip ["Traversal.FileModule"]
  defp read_blob(sha) do
    with true <- ArtifactStore.present?(sha),
         path = ArtifactStore.blob_path(sha),
         {:ok, %File.Stat{size: size}} when size <= @max_blob <- File.stat(path),
         {:ok, bytes} <- File.read(path) do
      case holds_root?(bytes) do
        :hit -> {:hit, size}
        :clean -> {:clean, size}
        {:error, _} -> {:error, size}
      end
    else
      _ -> {:error, 0}
    end
  end

  defp unread_bytes(row, state) do
    row.files
    |> Enum.reject(&Map.has_key?(state.cache, &1["sha256"]))
    |> Enum.map(&blob_size/1)
    |> Enum.sum()
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp blob_size(%{"sha256" => sha}) when is_binary(sha) do
    with true <- ArtifactStore.valid_sha256?(sha),
         {:ok, %File.Stat{size: size}} <- File.stat(ArtifactStore.blob_path(sha)) do
      size
    else
      _ -> 0
    end
  end

  defp blob_size(_file), do: 0

  defp row([id, system_pkg, name, version, manifest, variants, reason]) do
    variant_manifests = for %{"file_manifest" => m} <- List.wrap(variants), do: m

    files =
      [manifest | variant_manifests]
      |> Enum.flat_map(&ebin_entries/1)
      |> Enum.uniq_by(& &1["sha256"])

    %{
      id: Ecto.UUID.load!(id),
      package: name,
      version: version,
      system_pkg: system_pkg,
      reason: reason,
      holder: nil,
      files: files
    }
  end

  defp ebin_entries(%{"ebin" => entries}) when is_list(entries),
    do: Enum.filter(entries, &is_map/1)

  defp ebin_entries(_manifest), do: []

  defp act(%{confirmed: []} = report),
    do: {:withdrawn, 0, Map.put(report, :withdrawn_at, nil)}

  defp act(report) do
    at = NaiveDateTime.utc_now()
    ids = Enum.map(report.confirmed, &Ecto.UUID.dump!(&1.id))

    %{num_rows: count} =
      Repo.query!(@withdraw_sql, [ids, at, SystemResult.baked_build_path()])

    Logger.warning(
      "withdrew #{count} firmware publications holding the build tree at #{at}: " <>
        Enum.map_join(report.confirmed, ", ", &"#{&1.package} #{&1.version} #{&1.system_pkg}")
    )

    {:withdrawn, count, Map.put(report, :withdrawn_at, to_utc(at))}
  end

  # The IFF chunks this module reads, each once.
  defp chunks(<<>>, acc), do: {:ok, acc}

  defp chunks(<<id::binary-size(4), len::32, data::binary-size(len), rest::binary>>, acc) do
    pad = rem(4 - rem(len, 4), 4)

    rest =
      if byte_size(rest) >= pad, do: binary_part(rest, pad, byte_size(rest) - pad), else: <<>>

    acc = if id in @chunks, do: [{id, data} | acc], else: acc
    chunks(rest, acc)
  end

  defp chunks(_rest, _acc), do: {:error, "truncated beam"}

  # `LitT`: the inflated size, then the table, zlib-compressed unless the
  # size is 0 (OTP 28 writes it uncompressed).
  defp chunk_data("LitT", <<0::32, table::binary>>), do: {:ok, table}

  defp chunk_data("LitT", <<size::32, compressed::binary>>) when size <= @max_blob,
    do: inflate(compressed, 15, size)

  defp chunk_data("LitT", _data), do: {:error, "literal table too large"}
  defp chunk_data(_id, data), do: {:ok, data}

  defp hit?(bytes), do: :binary.match(bytes, @roots) != :nomatch

  # Inflates at most `max` bytes; more is an error, never a partial read.
  defp inflate(data, window_bits, max) do
    z = :zlib.open()

    try do
      :ok = :zlib.inflateInit(z, window_bits)
      inflated(z, :zlib.safeInflate(z, data), [], 0, max)
    rescue
      _ -> {:error, "inflate failed"}
    catch
      _, _ -> {:error, "inflate failed"}
    after
      :zlib.close(z)
    end
  end

  defp inflated(z, {status, out}, acc, size, max) when status in [:continue, :finished] do
    size = size + IO.iodata_length(out)

    cond do
      size > max -> {:error, "inflated past #{max} bytes"}
      status == :finished -> {:ok, IO.iodata_to_binary(Enum.reverse([out | acc]))}
      true -> inflated(z, :zlib.safeInflate(z, []), [out | acc], size, max)
    end
  end

  defp inflated(_z, _other, _acc, _size, _max), do: {:error, "inflate failed"}

  defp positive!(opts, key, default) do
    case Keyword.get(opts, key, default) do
      n when is_integer(n) and n > 0 -> n
      other -> raise ArgumentError, "#{key} must be a positive integer, got: #{inspect(other)}"
    end
  end

  defp cursor!(nil), do: nil

  defp cursor!(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> uuid
      :error -> raise ArgumentError, "after: must be a result id, got: #{inspect(id)}"
    end
  end

  defp cursor!(other),
    do: raise(ArgumentError, "after: must be a result id, got: #{inspect(other)}")

  defp dump(nil), do: nil
  defp dump(id), do: Ecto.UUID.dump!(id)

  defp naive_utc(%DateTime{} = at),
    do: at |> DateTime.shift_zone!("Etc/UTC") |> DateTime.to_naive()

  defp to_utc(%NaiveDateTime{} = at), do: DateTime.from_naive!(at, "Etc/UTC")
end
