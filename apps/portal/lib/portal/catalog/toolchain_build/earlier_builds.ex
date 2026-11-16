defmodule Portal.Catalog.ToolchainBuild.EarlierBuilds do
  @moduledoc """
  The builds of a toolchain build identity that a rebuild with another
  dependency lock replaced, kept on the row (`earlier_builds`) so they stay
  published.

  ## Why

  A row is one identity (`Portal.Catalog.ToolchainBuild`, "The identity"),
  and a rebuild of it replaces the row and its memberships. When the rebuild
  resolved a newer release of a dependency (`Portal.Workers.ClosureDrift`
  queues exactly those), the replaced build was made against the lock every
  project created before that release still has: `certifi 2.18.0` where a
  fresh `mix deps.get` now resolves `2.19.0`. A client takes a build only when
  its lock agrees with the build's `deps`, so replacing it would trade the
  hits of every locked project for those of fresh ones. Keeping it serves
  both: format 2 already lists one build per dependency lock
  (`Portal.Catalog.precompiled_manifest_v2/1`), and an earlier build is one
  more such build, at its own `finished_at`.

  ## Shape and cost

  Each entry is the served columns of the replaced row (`entry/1`), newest
  first, at most `max/0`, at most one per lock and never the row's own lock.
  Its files stay memberships of the row (`Portal.Catalog.Ingestion` keeps
  them), so publication, revocation and the batch fingerprint work by the row
  as before; a row that does not pass, or is revoked, serves none of them.
  Only a passing rebuild keeps them: one that does not pass is a verdict on
  the package's build (a refusal, a skip), not on one lock, and the ingest
  drops them with the row's own build. Nor does a passing rebuild of a row
  that served nothing (skipped or revoked) bring that row's entries back.

  Revocation is by row (`revoked_at`), and `Portal.Precompiled.ToolchainRevocation`
  picks rows by their verdict: `portability_rule` 2, with or without a
  `rule1_reason`, the `rule1_reason`'s prefix, and `judge_revision` at or
  above a revision. So an entry is kept only beside a row that every such
  revocation of the entry also selects (`covered?/2`, on the verdict columns
  recorded on the entry): the same `portability_rule` 2 or not, the same
  `rule1_reason`, and a `judge_revision` no lower than the entry's. The row
  then hides it. The manifest checks this again when it lists an entry
  (`expand/1`), since a release that does not know the column rewrites the
  row's verdict without looking at its entries.
  The blobs cost nothing extra: the store never deletes one, and a rebuild
  against a patch release of a dependency mostly compiles the same bytes.
  What is new is the entry (a few KB of JSON) and a membership per file that
  differs.

  An entry whose files are not all memberships of the row is left out whole
  (`Portal.Catalog.precompiled_manifest_v2/1` only lists a build whose every
  file it owns): what a release that does not know the column leaves behind,
  since its ingest replaces the memberships with its own build's alone.
  """

  alias Portal.Catalog.ToolchainBuild

  @max 3

  # The columns `Portal.Catalog.precompiled_manifest_v2/1` serves a toolchain
  # build from, and those `Portal.Precompiled.Withheld` reads it by.
  @fields [
    :elixir,
    :otp,
    :image_digest,
    :run_id,
    :deps_lock,
    :package_checksum,
    :declared,
    :manager,
    :compile_env,
    :compile_inputs,
    :compile_env_rule,
    :compile_env_run_id,
    :file_manifest
  ]

  # Not served, but what a revocation selects a build by (moduledoc).
  @verdict [:portability_rule, :rule1_reason, :judge_revision]

  @manifest_keys ["ebin", "priv"]

  @doc "How many earlier builds a row keeps."
  @spec max() :: pos_integer()
  def max, do: @max

  @doc """
  The build `row` serves, as an entry: its served columns, string keyed,
  with `finished_at` in ISO 8601. nil for a row that serves nothing: one that
  does not pass, is revoked, or has no lock or no files.
  """
  @spec entry(ToolchainBuild.t() | nil) :: map() | nil
  def entry(
        %ToolchainBuild{status: :pass, revoked_at: nil, deps_lock: %{}, file_manifest: %{}} = row
      ) do
    row
    |> Map.take(@fields ++ @verdict)
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
    |> Map.put("finished_at", row.finished_at && DateTime.to_iso8601(row.finished_at))
  end

  def entry(_row), do: nil

  @doc """
  The earlier builds after `replaced` (the row as it was, or nil) gave way to
  `new`, the row as the rebuild wrote it: none unless `new` passes, nor when
  `replaced` served nothing; else `replaced`'s own build first, then
  `earlier` (with no `replaced`, `earlier` alone), without
  any entry of `new`'s lock or that `new` does not cover (`covered?/2`), one
  per lock, at most `max/0`.
  """
  @spec push(ToolchainBuild.t() | nil, [map()] | nil, ToolchainBuild.t()) :: [map()]
  def push(replaced, earlier, %ToolchainBuild{status: :pass} = new) do
    case {replaced, entry(replaced)} do
      {nil, nil} -> List.wrap(earlier)
      # A row that served nothing hid its earlier builds with its own: a skip
      # or a refusal (which a release that does not know the column leaves
      # them beside) or a revocation. A passing rebuild does not revive them.
      {_replaced, nil} -> []
      {_replaced, entry} -> [entry | List.wrap(earlier)]
    end
    |> Enum.reject(&(&1["deps_lock"] == new.deps_lock))
    |> Enum.filter(&covered?(&1, new))
    |> Enum.uniq_by(& &1["deps_lock"])
    |> Enum.take(@max)
  end

  def push(_replaced, _earlier, _new), do: []

  @doc """
  Whether every `Portal.Precompiled.ToolchainRevocation` that would select
  the build `entry` records also selects `row`: both `portability_rule` 2 or
  neither, the same `rule1_reason` (a revocation takes it by prefix), and a
  `judge_revision` on `row` no lower than the entry's (a revocation takes
  every revision at or above one). An entry without a recorded revision key
  is not covered: its revision is unknown, not absent.
  """
  @spec covered?(map(), ToolchainBuild.t()) :: boolean()
  def covered?(entry, %ToolchainBuild{} = row) do
    entry["portability_rule"] == 2 == (row.portability_rule == 2) and
      entry["rule1_reason"] == row.rule1_reason and
      revision_covered?(Map.fetch(entry, "judge_revision"), row.judge_revision)
  end

  defp revision_covered?({:ok, nil}, _row_revision), do: true

  defp revision_covered?({:ok, revision}, row_revision)
       when is_integer(revision) and is_integer(row_revision),
       do: row_revision >= revision

  defp revision_covered?(_entry_revision, _row_revision), do: false

  @doc """
  The earlier builds of `row` with the build it serves now kept among them,
  before a rebuild that may replace it (`Portal.Workers.ClosureDrift`). The
  manifest lists the entry and the row as one build while both have the
  row's lock, and the ingest drops the entry again if the rebuild comes back
  with that lock.
  """
  @spec keep(ToolchainBuild.t()) :: [map()]
  def keep(row) do
    case entry(row) do
      nil -> List.wrap(row.earlier_builds)
      entry -> [entry | List.wrap(row.earlier_builds)]
    end
    |> Enum.uniq_by(& &1["deps_lock"])
    |> Enum.take(@max)
  end

  @doc "Every file sha the earlier builds list, which the row keeps as memberships."
  @spec shas([map()] | nil) :: [String.t()]
  def shas(earlier) do
    earlier
    |> List.wrap()
    |> Enum.flat_map(fn entry -> manifest_shas(entry["file_manifest"]) end)
    |> Enum.uniq()
  end

  defp manifest_shas(%{} = manifest) do
    for key <- @manifest_keys,
        entries = Map.get(manifest, key),
        is_list(entries),
        %{"sha256" => sha} <- entries,
        is_binary(sha) and sha != "",
        do: sha
  end

  defp manifest_shas(_manifest), do: []

  @doc """
  `row` followed by one row per earlier build: the row with the entry's
  columns in place of its own, the same id, version, toolchain, variant and
  config variant, and no earlier builds of its own. A manifest lists each as
  a build, judged by its own lock. An entry the row does not cover
  (`covered?/2`) is left out, and so is one of the row's own lock, the
  build a rebuild with that lock replaced: a release that does not know the
  column rewrites the row on a rebuild and leaves the entries as they were,
  so the checks at ingest alone do not hold. The manifest picks the newest
  build per lock within each list only, so an entry of the row's lock would
  stay listed wherever the row's compile inputs moved it from. `row` needs
  its `portability_rule`, `rule1_reason` and `judge_revision` loaded.
  """
  @spec expand(ToolchainBuild.t()) :: [ToolchainBuild.t()]
  def expand(%ToolchainBuild{earlier_builds: [_ | _] = earlier} = row) do
    [
      row
      | for(
          entry <- earlier,
          entry["deps_lock"] != row.deps_lock,
          covered?(entry, row),
          do: as_row(row, entry)
        )
    ]
  end

  def expand(row), do: [row]

  defp as_row(row, entry) do
    columns =
      Map.new(@fields, fn field -> {field, Map.get(entry, Atom.to_string(field))} end)

    row
    |> struct!(columns)
    |> Map.put(:finished_at, finished_at(entry["finished_at"]))
    |> Map.put(:earlier_builds, nil)
  end

  defp finished_at(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, at, _offset} -> at
      _ -> nil
    end
  end

  defp finished_at(_iso), do: nil
end
