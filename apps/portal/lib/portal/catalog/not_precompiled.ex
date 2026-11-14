defmodule Portal.Catalog.NotPrecompiled do
  @moduledoc """
  Why packages are not precompiled: the current `skipped` toolchain builds
  (`Portal.Catalog.ToolchainBuild`), each reason sorted into a root cause by
  `Portal.Catalog.SkipReasons`, for the admin Not precompiled tab.

  ## Which builds count

    * Revoked rows are left out, and so are the rows of a config variant
      other than `"default"` (`ToolchainBuild`, "Config variants"): a skip
      under a `phx_prod` overlay speaks only for clients with that config,
      the way `Portal.Catalog.toolchain_counts/0` counts default rows only.
      Both optional-dependency `variant`s count
      (`ToolchainBuild.optional_deps_variants/0`), and no other: a world
      build's skip speaks only for apps of that world's shape and clients
      that read `builds_closure`, and a newer release's variant is not read
      at all.
    * Per package and toolchain, only the newest version with a verdict
      counts: the highest version (stable before pre-release, as
      `Portal.Catalog.Coverage` picks) among the non-revoked rows whose
      status is not `:error`. An `:error` is a build still being retried, not
      a verdict, so a newer version with only errors leaves the older
      version's skip standing. A newer version that passed hides the older
      skip.
    * One row per package and reason: the toolchains (and variants) that
      skipped for the same reason collapse into one, with their toolchains
      listed and the highest version.

  A package skipped for two reasons counts once in each of their classes,
  so class counts can add up to more than the number of packages.

  Two queries, then classification in Elixir (once per distinct reason),
  memoised in `Portal.Catalog.Cache` because a LiveView mounts twice and
  the numbers change only with ingests. The aggregations below are pure
  functions over `rows/0`.
  """

  import Ecto.Query, only: [from: 2]

  alias Portal.Catalog.{Cache, SkipReasons, ToolchainBuild}
  alias Portal.Repo

  @default_config "default"
  @variants Enum.map(ToolchainBuild.optional_deps_variants(), &Atom.to_string/1)

  @type row :: %{
          package: String.t(),
          downloads: non_neg_integer(),
          version: String.t(),
          toolchains: [String.t()],
          reason: String.t() | nil,
          class: SkipReasons.class(),
          detail: String.t() | nil,
          blocker: String.t() | nil
        }

  @doc "Every current skip, one per package and reason, by downloads descending."
  @spec rows() :: [row()]
  def rows, do: Cache.fetch(:not_precompiled_rows, &compute_rows/0)

  defp compute_rows do
    latest = latest_versions()

    skipped =
      Repo.all(
        from(b in "catalog_toolchain_builds",
          join: p in "catalog_packages",
          on: p.id == b.package_id,
          where:
            is_nil(b.revoked_at) and b.status == "skipped" and
              b.config_variant == ^@default_config and b.variant in ^@variants,
          distinct: true,
          select: %{
            package_id: b.package_id,
            package: p.name,
            downloads: p.hex_downloads_recent,
            toolchain: b.toolchain,
            version: b.version,
            reason: b.reason
          }
        )
      )

    current =
      Enum.filter(skipped, &(Map.get(latest, {&1.package_id, &1.toolchain}) == &1.version))

    classes =
      current |> Enum.map(& &1.reason) |> Enum.uniq() |> Map.new(&{&1, SkipReasons.classify(&1)})

    current
    |> Enum.group_by(&{&1.package, &1.reason})
    |> Enum.map(fn {{package, reason}, builds} ->
      [first | _] = builds

      Map.merge(classes[reason], %{
        package: package,
        downloads: first.downloads || 0,
        version: builds |> Enum.map(& &1.version) |> highest(),
        toolchains: builds |> Enum.map(& &1.toolchain) |> Enum.uniq() |> Enum.sort(),
        reason: reason
      })
    end)
    |> Enum.sort_by(&{-&1.downloads, &1.package, &1.reason || ""})
  end

  # `{package_id, toolchain} => newest version with a verdict`.
  defp latest_versions do
    from(b in "catalog_toolchain_builds",
      where:
        is_nil(b.revoked_at) and b.status != "error" and b.config_variant == ^@default_config and
          b.variant in ^@variants,
      distinct: true,
      select: {b.package_id, b.toolchain, b.version}
    )
    |> Repo.all()
    |> Enum.group_by(fn {id, toolchain, _} -> {id, toolchain} end, &elem(&1, 2))
    |> Map.new(fn {key, versions} -> {key, highest(versions)} end)
  end

  # Stable before pre-release; an unparsable version only when nothing parses.
  defp highest(versions) do
    parsed =
      for version <- Enum.uniq(versions), {:ok, v} <- [Version.parse(version)], do: {v, version}

    case {Enum.reject(parsed, fn {v, _} -> v.pre != [] end), parsed} do
      {[], []} -> versions |> Enum.uniq() |> Enum.max()
      {[], all} -> max_version(all)
      {stable, _} -> max_version(stable)
    end
  end

  defp max_version(pairs), do: pairs |> Enum.max_by(&elem(&1, 0), Version) |> elem(1)

  @doc """
  Per class: distinct packages and their summed recent downloads, in
  `SkipReasons.classes/0` order, classes without packages left out.
  """
  @spec by_class([row()]) :: [
          %{class: SkipReasons.class(), packages: non_neg_integer(), downloads: non_neg_integer()}
        ]
  def by_class(rows) do
    grouped = Enum.group_by(rows, & &1.class)

    for class <- SkipReasons.classes(),
        class_rows = Map.get(grouped, class, []),
        class_rows != [] do
      packages = unique_packages(class_rows)

      %{
        class: class,
        packages: length(packages),
        downloads: packages |> Enum.map(& &1.downloads) |> Enum.sum()
      }
    end
  end

  @doc "Within `class`, per `detail` (nil included): distinct packages, most first."
  @spec by_detail([row()], SkipReasons.class()) :: [
          %{detail: String.t() | nil, packages: non_neg_integer()}
        ]
  def by_detail(rows, class) do
    rows
    |> Enum.filter(&(&1.class == class))
    |> Enum.group_by(& &1.detail)
    |> Enum.map(fn {detail, group} ->
      %{detail: detail, packages: length(unique_packages(group))}
    end)
    |> Enum.sort_by(&{-&1.packages, &1.detail || ""})
  end

  @doc """
  Per blocking closure dependency: the distinct packages it blocks, their
  summed downloads and the `sample` most downloaded of them, most packages
  first.
  """
  @spec by_blocker([row()], pos_integer()) :: [
          %{
            blocker: String.t(),
            packages: non_neg_integer(),
            downloads: non_neg_integer(),
            sample: [String.t()]
          }
        ]
  def by_blocker(rows, sample \\ 3) do
    rows
    |> Enum.filter(& &1.blocker)
    |> Enum.group_by(& &1.blocker)
    |> Enum.map(fn {blocker, group} ->
      packages = unique_packages(group)

      %{
        blocker: blocker,
        packages: length(packages),
        downloads: packages |> Enum.map(& &1.downloads) |> Enum.sum(),
        sample: packages |> Enum.take(sample) |> Enum.map(& &1.package)
      }
    end)
    |> Enum.sort_by(&{-&1.packages, -&1.downloads, &1.blocker})
  end

  @doc """
  The rows matching `filters` (`:class`, `:detail`, `:blocker`; a nil or
  missing filter matches everything), by downloads descending.
  """
  @spec filter([row()], keyword()) :: [row()]
  def filter(rows, filters) do
    Enum.filter(rows, fn row ->
      Enum.all?(filters, fn
        {_key, nil} -> true
        {key, value} when key in [:class, :detail, :blocker] -> Map.get(row, key) == value
        _other -> true
      end)
    end)
  end

  # One row per package, the first (most downloaded) kept; `rows` is sorted
  # by downloads already.
  defp unique_packages(rows) do
    rows
    |> Enum.uniq_by(& &1.package)
    |> Enum.sort_by(&{-&1.downloads, &1.package})
  end
end
