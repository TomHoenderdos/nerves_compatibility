defmodule Portal.Workers.SystemAbiObserve do
  @moduledoc """
  Hourly Oban cron (queue `:maintenance`) that keeps up with new releases
  of the Nerves systems published native builds target, so a build made on
  one release can be matched on a release the portal never built on.

  Each perform records the toolchain requirement of every new Hex release
  (`Portal.Precompiled.SystemAbi.sync_requirements/0`), then queues one
  `Portal.Workers.SystemAbiRun` for up to eight releases, newest first,
  whose `catalog_system_abi` row has no library table and whose system has
  a published native build. A release already in a run that has not
  finished, asked in the last day, or failed for good is left out
  (`Portal.Workers.SystemAbiRun.askable/1`).
  """

  use Oban.Worker,
    queue: :maintenance,
    unique: [period: :infinity, states: :incomplete]

  alias Portal.Precompiled.SystemAbi
  alias Portal.Repo
  alias Portal.Workers.SystemAbiRun

  # Rows without libraries whose system has a published native build.
  @without_libs """
  SELECT a.system_pkg, a.version
  FROM catalog_system_abi a
  WHERE a.libs IS NULL
    AND EXISTS (
      SELECT 1
      FROM catalog_system_results s
      JOIN catalog_runs r ON r.id = s.run_id
      WHERE s.system_pkg = a.system_pkg AND s.native
        AND s.unpublished_at IS NULL AND r.revoked_at IS NULL
    )
  """

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    :ok = SystemAbi.sync_requirements()

    without_libs()
    |> Enum.sort(&newer?/2)
    |> SystemAbiRun.askable()
    |> Enum.take(SystemAbiRun.max_pairs())
    |> SystemAbiRun.schedule(1)

    :ok
  end

  # The statement is a module constant with no parameters.
  # sobelow_skip ["SQL.Query"]
  defp without_libs do
    %{rows: rows} = Repo.query!(@without_libs)
    Enum.map(rows, fn [system, version] -> %{"system" => system, "version" => version} end)
  end

  # Newest first: a version that parses before one that does not, then by
  # version, then by system name.
  defp newer?(a, b) do
    case {Version.parse(a["version"]), Version.parse(b["version"])} do
      {{:ok, va}, {:ok, vb}} ->
        case Version.compare(va, vb) do
          :gt -> true
          :lt -> false
          :eq -> a["system"] <= b["system"]
        end

      {{:ok, _va}, :error} ->
        true

      {:error, {:ok, _vb}} ->
        false

      {:error, :error} ->
        {a["version"], a["system"]} >= {b["version"], b["system"]}
    end
  end
end
