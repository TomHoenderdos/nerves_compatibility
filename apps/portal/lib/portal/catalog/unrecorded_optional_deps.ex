defmodule Portal.Catalog.UnrecordedOptionalDeps do
  @max_packages 200

  @moduledoc """
  The `with` toolchain builds written before builds recorded their optional
  dependencies (`optional_deps` is nil) whose package still needs a `without`
  build, for `Portal.Catalog.toolchain_backlog/3`.

  Such a row says nothing about what the worker added. The registry does: a
  version that declares an optional Hex dependency the worker would add (one
  not on `Compatibility.OptionalDeps.never_added/0`) gets a `without` build,
  and one that declares only required dependencies or only never-added
  tooling does not, since its two builds would be the same.

  The check reads `repo.hex.pm` (`releases/2` of `config :portal, :hex_deps`,
  else `Portal.HexDeps`, which caches each answer for an hour) and so runs in
  Elixir on a small set rather than in the backlog query: at most
  #{@max_packages} packages per call, most downloaded first, and only rows whose
  `without` build is not settled yet (no `pass` or `skipped` row, nothing
  revoked). A package the registry cannot answer for, or does not list, is
  left out of this call and asked again on the next.

  A version the registry lists with no dependency to add is recorded as such
  on its row (`optional_deps` `%{"added" => [], "reason" => "unrecorded_none"}`,
  `ToolchainBuild`'s `:record_optional_deps`), which takes it out of this set
  for good: otherwise the most downloaded packages, once all of them declare
  nothing, would fill every call and the ones behind them would never be
  asked about. A recorded `added` that is empty wants no `without` build, as
  for a build that reported it, and the row's status, files and dates, and so
  what is served, stay as they are.
  """

  require Ash.Query

  alias Compatibility.OptionalDeps
  alias Portal.Catalog.ToolchainBuild
  alias Portal.Repo

  @none %{"added" => [], "reason" => "unrecorded_none"}

  @doc """
  The `{packages, versions}` (two lists, pairwise) of unrecorded `with` rows on
  `toolchain` at `builder_version` whose version declares an optional
  dependency the worker would add. Rows of a version the registry lists
  without one are recorded as declaring none (see the moduledoc).

  Options: `:hex_releases` (`(String.t() -> {:ok, [release]} | {:error, term()})`,
  default `releases/2` of `config :portal, :hex_deps` with a short timeout).
  """
  @spec wanted(String.t(), pos_integer(), keyword()) :: {[String.t()], [String.t()]}
  def wanted(toolchain, builder_version, opts \\ []) do
    hex_releases = Keyword.get_lazy(opts, :hex_releases, &default_hex_releases/0)

    {wanted, none} =
      toolchain
      |> unrecorded(builder_version)
      |> Enum.group_by(fn [package, _version, _id] -> package end, fn [_package, version, id] ->
        {version, id}
      end)
      |> Enum.map(fn {package, versions} -> declaring(package, versions, hex_releases) end)
      |> Enum.unzip()

    record_none(List.flatten(none))
    wanted |> List.flatten() |> Enum.unzip()
  end

  # `{wanted, none}`: the `{package, version}` pairs that declare a dependency
  # to add, and the ids of the rows whose version the registry lists without
  # one. A version it does not list, like a package it cannot answer for, is
  # in neither.
  defp declaring(package, versions, hex_releases) do
    case hex_releases.(package) do
      {:ok, releases} ->
        Enum.reduce(versions, {[], []}, &sort_version(package, releases, &1, &2))

      _ ->
        {[], []}
    end
  end

  defp sort_version(package, releases, {version, id}, {wanted, none}) do
    case declares(releases, version) do
      true -> {[{package, version} | wanted], none}
      false -> {wanted, [id | none]}
      :unknown -> {wanted, none}
    end
  end

  defp record_none([]), do: :ok

  defp record_none(ids) do
    ToolchainBuild
    |> Ash.Query.filter(id in ^ids)
    |> Ash.bulk_update!(:record_optional_deps, %{optional_deps: @none},
      domain: Portal.Catalog,
      strategy: :atomic
    )

    :ok
  end

  @doc """
  Whether a Hex dependency is one the worker adds in a `with` build: optional,
  from hexpm, and not on `Compatibility.OptionalDeps.never_added/0`.
  """
  @spec addable?(Portal.HexDeps.dep()) :: boolean()
  def addable?(dep) do
    dep.optional and dep.repository == "hexpm" and dep.package not in OptionalDeps.never_added()
  end

  defp declares(releases, version) do
    case Enum.find(releases, &(&1.version == version)) do
      %{deps: deps} -> Enum.any?(deps, &addable?/1)
      nil -> :unknown
    end
  end

  defp unrecorded(toolchain, builder_version) do
    %{rows: rows} =
      Repo.query!(
        """
        WITH legacy AS (
          SELECT w.id, p.name AS package, w.version, p.hex_downloads_recent AS recent
          FROM catalog_toolchain_builds w
          JOIN catalog_packages p ON p.id = w.package_id
          WHERE w.toolchain = $1
            AND w.builder_version = $2
            AND w.variant = 'with'
            AND w.status = 'pass'
            AND w.revoked_at IS NULL
            AND w.optional_deps IS NULL
            AND NOT EXISTS (
              SELECT 1 FROM catalog_toolchain_builds o
              WHERE o.package_id = w.package_id
                AND o.version = w.version
                AND o.toolchain = w.toolchain
                AND o.builder_version = w.builder_version
                AND o.variant = 'without'
                AND (o.status IN ('pass', 'skipped') OR o.revoked_at IS NOT NULL)
            )
        ), top AS (
          SELECT package, recent FROM legacy
          GROUP BY package, recent
          ORDER BY recent DESC NULLS LAST, package
          LIMIT $3
        )
        SELECT l.package, l.version, l.id
        FROM legacy l
        JOIN top t ON t.package = l.package
        ORDER BY l.package, l.version
        """,
        [toolchain, builder_version, @max_packages]
      )

    rows
  end

  defp default_hex_releases do
    hex_deps = Application.get_env(:portal, :hex_deps, Portal.HexDeps)
    opts = [retry: false, receive_timeout: 10_000, connect_options: [timeout: 5_000]]
    &hex_deps.releases(&1, opts)
  end
end
