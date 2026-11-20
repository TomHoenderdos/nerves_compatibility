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

  Each entry is the served columns of the replaced row (`entry/1`) and its
  verdict, newest first, at most `max/0`, at most one per lock and never
  the row's own lock. Its files stay memberships of the row
  (`Portal.Catalog.Ingestion` keeps them). Only a passing rebuild keeps
  them: one that does not pass is a verdict on the package's build (a
  refusal, a skip), not on one lock, and the ingest drops them with the
  row's own build. Nor does a passing rebuild of a row that served nothing
  (skipped or revoked) bring that row's entries back.
  The blobs cost nothing extra: the store never deletes one, and a rebuild
  against a patch release of a dependency mostly compiles the same bytes.
  What is new is the entry (a few KB of JSON) and a membership per file that
  differs.

  ## Served as a virtual row

  An entry is served as a row of its own (`virtual_rows/1`): the row's id,
  identity (package, version, toolchain, builder version, variant, config
  variant) and served-ness (`status`, `revoked_at`), with its own lock,
  compile inputs, `compile_env`, config reads, file manifest and
  `finished_at`. Every reader of published toolchain builds judges it by
  the same predicate as a row, and only beside a row that predicate
  serves: `Portal.Catalog.precompiled_manifest_v2/1` (`builds`,
  `builds_with_inputs` and `builds_closure` alike), the files route
  (`Portal.Catalog.published_sha256?/1`, which serves a file only for a
  build whose own manifest lists it) and the package list the batch is
  built from. A build whose files are not all memberships of the row and
  present is left out whole, as a row's is: what a release that does not
  know the column leaves behind, since its ingest replaces the
  memberships with its own build's alone.

  A revocation (`Portal.Precompiled.ToolchainRevocation`) judges each
  entry by its own recorded verdict (`portability_rule`, `rule1_reason`,
  `judge_revision`) and revokes the row when the row or any of its entries
  matches, which hides them all: the served-ness is the row's.
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
    :file_manifest,
    :foreign_priv,
    :foreign_priv_rule,
    :foreign_priv_run_id
  ]

  # Not served, but what a revocation judges an entry by (moduledoc).
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
  any entry of `new`'s lock, one per lock, at most `max/0`.
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
    |> Enum.uniq_by(& &1["deps_lock"])
    |> Enum.take(@max)
  end

  def push(_replaced, _earlier, _new), do: []

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

  @doc """
  Every file sha the earlier builds list, which the row keeps as
  memberships: their manifests' files, and the foreign priv files of an
  entry whose list is still its own run's (`Portal.Precompiled.ForeignPriv.counted/1`).
  """
  @spec shas([map()] | nil) :: [String.t()]
  def shas(earlier) do
    earlier
    |> List.wrap()
    |> Enum.flat_map(fn entry -> manifest_shas(entry["file_manifest"]) ++ foreign_shas(entry) end)
    |> Enum.uniq()
  end

  defp foreign_shas(%{
         "foreign_priv" => [_ | _] = list,
         "run_id" => run,
         "foreign_priv_run_id" => run
       })
       when is_binary(run),
       do: for(%{"sha256" => sha} <- list, is_binary(sha) and sha != "", do: sha)

  defp foreign_shas(_entry), do: []

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
  The virtual rows of `row`'s earlier builds (moduledoc, "Served as a
  virtual row"): `row` with each entry's columns in place of its own and no
  earlier builds of its own. An entry of `row`'s own lock has none: that
  lock's build is the row's, and a release that does not know the column
  can leave the one a rebuild replaced beside it. The caller serves them
  only beside a row it serves.
  """
  @spec virtual_rows(ToolchainBuild.t()) :: [ToolchainBuild.t()]
  def virtual_rows(%ToolchainBuild{earlier_builds: [_ | _] = earlier} = row) do
    for entry <- earlier, entry["deps_lock"] != row.deps_lock, do: as_row(row, entry)
  end

  def virtual_rows(_row), do: []

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
