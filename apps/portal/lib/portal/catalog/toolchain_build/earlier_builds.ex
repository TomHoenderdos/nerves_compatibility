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
  drops them with the row's own build.

  Revocation is by row (`revoked_at`), and `Portal.Precompiled.ToolchainRevocation`
  picks rows by their verdict: `portability_rule` 2, with or without a
  `rule1_reason`. So an entry is kept only beside a row of the same verdict
  class (`portability_rule` 2 or not, and a `rule1_reason` or not, both
  recorded on the entry): any revocation that would select the entry's build
  then selects the row, and the row hides it.
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
  @verdict [:portability_rule, :rule1_reason]

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
  `new`, the row as the rebuild wrote it: none unless `new` passes; else
  `replaced`'s own build first when it served one, then `earlier`, without
  any entry of `new`'s lock or of another verdict class, one per lock, at
  most `max/0`.
  """
  @spec push(ToolchainBuild.t() | nil, [map()] | nil, ToolchainBuild.t()) :: [map()]
  def push(replaced, earlier, %ToolchainBuild{status: :pass} = new) do
    case entry(replaced) do
      nil -> List.wrap(earlier)
      entry -> [entry | List.wrap(earlier)]
    end
    |> Enum.reject(&(&1["deps_lock"] == new.deps_lock))
    |> Enum.filter(&(class(&1) == class(new)))
    |> Enum.uniq_by(& &1["deps_lock"])
    |> Enum.take(@max)
  end

  def push(_replaced, _earlier, _new), do: []

  defp class(%ToolchainBuild{} = row), do: {row.portability_rule == 2, row.rule1_reason != nil}
  defp class(entry), do: {entry["portability_rule"] == 2, entry["rule1_reason"] != nil}

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
  a build, judged by its own lock.
  """
  @spec expand(ToolchainBuild.t()) :: [ToolchainBuild.t()]
  def expand(%ToolchainBuild{earlier_builds: [_ | _] = earlier} = row) do
    [row | Enum.map(earlier, &as_row(row, &1))]
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
