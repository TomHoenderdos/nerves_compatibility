defmodule Portal.Workers.SystemAbiBackfill do
  @moduledoc """
  Oban worker (queue `:maintenance`, the admin Maintenance page's "Backfill
  system ABI" button, no cron) that gives target builds published before
  their ABI facts were recorded what matching them on another release of
  their system needs. Each perform:

    1. reads the ELF facts (`Portal.Precompiled.ElfFacts.store_for/1`) of up
       to 500 published target results with priv files and a null
       `native`, by id, marking each `elf_checked_at` so a result whose blob
       cannot be read is not read again; it snoozes 60 s while more remain;
    2. fills the toolchain and OTP of published passing target results from
       their release's `catalog_system_abi` row (`fill_release_facts/1`);
    3. queues `Portal.Workers.SystemAbiRun`s, eight pairs each and at most
       ten per perform, for the releases of published native, portable
       results that have no library table yet, snoozing 60 s while more
       remain.

  It is `:ok` when nothing remains. The ELF blobs are in the web host's
  `Portal.ArtifactStore`, which is why it runs on `:maintenance`; the runs
  it queues go to the build nodes.
  """

  use Oban.Worker,
    queue: :maintenance,
    unique: [period: :infinity, states: :incomplete]

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Portal.Precompiled.ElfFacts
  alias Portal.Repo
  alias Portal.Workers.SystemAbiRun

  @batch 500
  @max_runs 10
  @snooze_s 60
  @host_systems ["host", "pure_elixir"]

  @doc "Queue a backfill now; one already pending is returned instead."
  @spec enqueue() :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue, do: %{} |> new() |> Oban.insert()

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    if read_elf_facts() == :more do
      {:snooze, @snooze_s}
    else
      fill_release_facts()

      case SystemAbiRun.schedule(missing_releases(), @max_runs) do
        {_queued, true} -> {:snooze, @snooze_s}
        {_queued, false} -> :ok
      end
    end
  end

  defp read_elf_facts do
    candidates = elf_candidates()
    {batch, rest} = Enum.split(candidates, @batch)

    Enum.each(batch, fn %{id: id, system_pkg: system_pkg} ->
      store_elf_facts(id, system_pkg)
      mark_checked(id)
    end)

    if rest == [], do: :done, else: :more
  end

  defp store_elf_facts(id, system_pkg) do
    case ElfFacts.store_for(id) do
      {:ok, _row} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "System ABI backfill could not read the ELF facts of #{system_pkg} result #{id}: " <>
            inspect(reason)
        )
    end
  rescue
    error ->
      Logger.warning(
        "System ABI backfill could not read the ELF facts of #{system_pkg} result #{id}: " <>
          Exception.message(error)
      )
  end

  defp mark_checked(id) do
    from(s in "catalog_system_results", where: s.id == type(^id, Ecto.UUID))
    |> Repo.update_all(set: [elf_checked_at: DateTime.utc_now()])
  end

  # Published target results with priv files whose facts were never read,
  # one past the batch so the caller knows whether more remain. Carried
  # copies are read too: they publish the same files as the result they
  # copy, and were copied before it had facts.
  defp elf_candidates do
    from(s in "catalog_system_results",
      join: r in "catalog_runs",
      on: r.id == s.run_id,
      where: is_nil(s.unpublished_at) and is_nil(r.revoked_at),
      where: s.system_pkg not in ^@host_systems,
      where: is_nil(s.native) and is_nil(s.elf_checked_at),
      where:
        fragment(
          "jsonb_array_length(coalesce(? #> '{footprint,file_manifest,priv}', '[]'::jsonb)) > 0",
          s.beam_scan
        ),
      order_by: s.id,
      limit: ^(@batch + 1),
      select: %{id: type(s.id, Ecto.UUID), system_pkg: s.system_pkg}
    )
    |> Repo.all()
  end

  # The toolchain only from a row whose toolchain a lock resolved (a
  # requirement row's is a requirement), both columns together; OTP from any
  # row that has one. A value a build already recorded is never replaced.
  @fill_toolchain """
  UPDATE catalog_system_results s
  SET toolchain_pkg = a.toolchain_pkg, toolchain_version = a.toolchain_version
  FROM catalog_system_abi a, catalog_runs r
  WHERE a.system_pkg = s.system_pkg AND a.version = s.system_version
    AND r.id = s.run_id AND s.unpublished_at IS NULL AND r.revoked_at IS NULL
    AND s.status = 'pass' AND NOT (s.system_pkg = ANY($1))
    AND s.toolchain_pkg IS NULL AND s.toolchain_version IS NULL
    AND a.source = 'lock' AND a.toolchain_pkg IS NOT NULL AND a.toolchain_version IS NOT NULL
    AND ($2::text[] IS NULL OR s.system_pkg || '@' || s.system_version = ANY($2))
  """

  @fill_otp """
  UPDATE catalog_system_results s
  SET otp_full = a.otp
  FROM catalog_system_abi a, catalog_runs r
  WHERE a.system_pkg = s.system_pkg AND a.version = s.system_version
    AND r.id = s.run_id AND s.unpublished_at IS NULL AND r.revoked_at IS NULL
    AND s.status = 'pass' AND NOT (s.system_pkg = ANY($1))
    AND s.otp_full IS NULL AND a.otp IS NOT NULL
    AND ($2::text[] IS NULL OR s.system_pkg || '@' || s.system_version = ANY($2))
  """

  @doc """
  Fills the null `toolchain_pkg`/`toolchain_version` (from a `"lock"` row
  only) and `otp_full` of published passing target results from the
  `catalog_system_abi` row of their release; for every release, or only for
  `pairs` (`%{"system", "version"}`).
  """
  @spec fill_release_facts(:all | [SystemAbiRun.pair()]) :: :ok
  # The statements are module constants; the values are bound parameters.
  # sobelow_skip ["SQL.Query"]
  def fill_release_facts(pairs \\ :all) do
    keys =
      case pairs do
        :all -> nil
        pairs -> Enum.map(pairs, &(&1["system"] <> "@" <> &1["version"]))
      end

    for sql <- [@fill_toolchain, @fill_otp], do: Repo.query!(sql, [@host_systems, keys])
    :ok
  end

  # Releases of published native, portable results whose row has no library
  # table (or that have no row at all), by name and version.
  defp missing_releases do
    from(s in "catalog_system_results",
      join: r in "catalog_runs",
      on: r.id == s.run_id,
      left_join: a in "catalog_system_abi",
      on: a.system_pkg == s.system_pkg and a.version == s.system_version,
      where: is_nil(s.unpublished_at) and is_nil(r.revoked_at),
      where: s.native == true and s.portable == true,
      where: s.system_pkg not in ^@host_systems and not is_nil(s.system_version),
      where: is_nil(a.libs),
      distinct: true,
      order_by: [s.system_pkg, s.system_version],
      select: %{"system" => s.system_pkg, "version" => s.system_version}
    )
    |> Repo.all()
  end
end
