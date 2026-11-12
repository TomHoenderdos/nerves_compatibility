defmodule Portal.Catalog.RunMemoryStats do
  @moduledoc """
  Read-only views over `Portal.Catalog.RunMemory`: per-package peaks and OOM
  kills for the admin Memory tab, the warm runs as one summary, and the
  newest rows of one package for its page.

  An OOM-killed run counts as peaking at the limit it died at: the sampler
  reads every 5 s, so its last record (if it wrote one at all) understates
  what the kernel saw.
  """

  import Ecto.Query, only: [from: 2, subquery: 1]

  require Ash.Query

  alias Portal.Catalog.RunMemory
  alias Portal.Repo

  @window_days 30
  @sorts [:peak, :oom, :runs, :name]

  @type row :: %{
          package: String.t(),
          kind: :firmware | :toolchain,
          runs: non_neg_integer(),
          oom_kills: non_neg_integer(),
          last_peak_used_bytes: non_neg_integer() | nil,
          max_peak_used_bytes: non_neg_integer() | nil,
          p90_peak_used_bytes: non_neg_integer() | nil,
          last_limit_bytes: non_neg_integer() | nil,
          last_finished_at: DateTime.t() | nil
        }

  @doc "The sorts `per_package/1` takes."
  def sorts, do: @sorts

  @doc """
  One row per `(package, kind)` of the firmware and toolchain runs that
  finished in the last #{@window_days} days.

  Options: `:kind` (`:firmware | :toolchain | :all`, default `:all`),
  `:sort` (`:peak | :oom | :runs | :name`, default `:peak`, all but `:name`
  descending), `:limit` (default 200).
  """
  @spec per_package(keyword()) :: [row()]
  def per_package(opts \\ []) do
    kinds =
      case Keyword.get(opts, :kind, :all) do
        :firmware -> ["firmware"]
        :toolchain -> ["toolchain"]
        _all -> ["firmware", "toolchain"]
      end

    # An OOM-killed run peaked at its limit, whatever its last sample said.
    runs =
      from(r in "catalog_run_memory",
        where: r.finished_at >= ^since() and not is_nil(r.package) and r.kind in ^kinds,
        select: %{
          package: r.package,
          kind: r.kind,
          oom_killed: r.oom_killed,
          limit: r.memory_limit_bytes,
          finished_at: r.finished_at,
          peak:
            fragment(
              "CASE WHEN ? AND ? IS NOT NULL THEN ? ELSE ? END",
              r.oom_killed,
              r.memory_limit_bytes,
              r.memory_limit_bytes,
              r.peak_used_bytes
            )
        }
      )

    grouped =
      from(r in subquery(runs),
        group_by: [r.package, r.kind],
        select: %{
          package: r.package,
          kind: r.kind,
          runs: count(),
          oom_kills: fragment("count(*) FILTER (WHERE ?)", r.oom_killed),
          last_peak_used_bytes:
            fragment(
              "(array_agg(? ORDER BY ? DESC) FILTER (WHERE ? IS NOT NULL))[1]",
              r.peak,
              r.finished_at,
              r.peak
            ),
          max_peak_used_bytes: max(r.peak),
          p90_peak_used_bytes:
            fragment("round(percentile_cont(0.9) WITHIN GROUP (ORDER BY ?))::bigint", r.peak),
          last_limit_bytes:
            fragment(
              "(array_agg(? ORDER BY ? DESC) FILTER (WHERE ? IS NOT NULL))[1]",
              r.limit,
              r.finished_at,
              r.limit
            ),
          last_finished_at: type(max(r.finished_at), :utc_datetime_usec)
        }
      )

    from(s in subquery(grouped), limit: ^Keyword.get(opts, :limit, 200))
    |> order(Keyword.get(opts, :sort, :peak))
    |> Repo.all()
    |> Enum.map(&%{&1 | kind: kind_atom(&1.kind)})
  end

  defp order(query, :oom),
    do:
      from(s in query,
        order_by: [desc: s.oom_kills, desc_nulls_last: s.max_peak_used_bytes, asc: s.package]
      )

  defp order(query, :runs),
    do: from(s in query, order_by: [desc: s.runs, asc: s.package, asc: s.kind])

  defp order(query, :name), do: from(s in query, order_by: [asc: s.package, asc: s.kind])

  defp order(query, _peak),
    do:
      from(s in query,
        order_by: [desc_nulls_last: s.max_peak_used_bytes, asc: s.package, asc: s.kind]
      )

  @doc "The warm runs of the last #{@window_days} days: how many and their max peak."
  @spec warm_summary() :: %{runs: non_neg_integer(), max_peak_used_bytes: integer() | nil}
  def warm_summary do
    from(r in "catalog_run_memory",
      where: r.finished_at >= ^since() and r.kind == "warm",
      select: %{runs: count(r.id), max_peak_used_bytes: max(r.peak_used_bytes)}
    )
    |> Repo.one()
  end

  @doc """
  The newest firmware and the newest toolchain row of `name`, whatever their
  age; nil when it has neither.
  """
  @spec latest_for_package(String.t()) ::
          %{firmware: RunMemory.t() | nil, toolchain: RunMemory.t() | nil} | nil
  def latest_for_package(name) when is_binary(name) do
    case {latest(name, :firmware), latest(name, :toolchain)} do
      {nil, nil} -> nil
      {firmware, toolchain} -> %{firmware: firmware, toolchain: toolchain}
    end
  end

  defp latest(name, kind) do
    RunMemory
    |> Ash.Query.filter(package == ^name and kind == ^kind)
    |> Ash.Query.sort(finished_at: :desc_nils_last)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(domain: Portal.Catalog)
  end

  defp since, do: DateTime.add(DateTime.utc_now(), -@window_days * 86_400, :second)

  defp kind_atom("firmware"), do: :firmware
  defp kind_atom("toolchain"), do: :toolchain
end
