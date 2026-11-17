defmodule Portal.ObanConfigTest do
  @moduledoc """
  Guards two Oban settings whose only failure mode is silent and expensive.
  """
  use ExUnit.Case, async: true

  alias Portal.BuildCache.L2.Prefetch
  alias Portal.BuildCache.Promotion
  alias Portal.Builder

  defp plugins, do: Application.get_env(:portal, Oban)[:plugins]

  defp plugin(name), do: Enum.find(plugins(), &match?({^name, _opts}, &1))

  test "the Pruner keeps finished jobs for 12 hours" do
    {_mod, opts} = plugin(Oban.Plugins.Pruner)

    # `max_age` is in seconds, unlike Lifeline's `rescue_after` (milliseconds):
    # `:timer.hours(6)` here kept every finished job for about 250 days.
    assert opts[:max_age] == 12 * 60 * 60
  end

  test "Lifeline rescues only well after a build's own wall clock" do
    {_mod, opts} = plugin(Oban.Plugins.Lifeline)

    # Rescuing is purely time-based. When `rescue_after` sat at exactly
    # `total_timeout_ms/0`, a build running up against its own deadline could be
    # rescued while still executing — a second container and a second
    # multi-gigabyte scratch tree for work already in flight.
    assert opts[:rescue_after] > Builder.total_timeout_ms()

    # The job also spends, outside the container's wall clock, the L2
    # prefetch before it, and the L2 uploads and the Hex cache promotion
    # after it, each under a budget of its own. Rescue must wait out all four,
    # the promotion's bounded overrun past its budget included.
    assert opts[:rescue_after] >
             Builder.total_timeout_ms() + Prefetch.budget_ms() +
               Promotion.l2_upload_budget_ms() + Compatibility.HexCache.budget_ms() +
               Compatibility.HexCache.max_overrun_ms()
  end

  # The closure drift run reads Hex once per closure member, up to 15 s a
  # read and nearly two thousand members a day. Rescued while still reading,
  # it would run a second time beside the first, queueing its rebuilds
  # again. Past its budget it reads and judges nothing more; what is in
  # flight then (one Hex read, one candidates query of at most 2 minutes)
  # fits in the margin.
  test "Lifeline rescues the closure drift run only well after its time budget" do
    {_mod, opts} = plugin(Oban.Plugins.Lifeline)

    assert opts[:rescue_after] >
             Portal.Workers.ClosureDrift.budget_ms() + :timer.minutes(5)
  end

  # `Oban.Plugins.Cron` inserts on the leader only, with one queue for every
  # node. While that queue was the shared `:ingest` one, each hour's sweep ran
  # on whichever builder fetched it first and the other disks went unswept.
  test "every build node queues its own hourly sweep, on its own node queue" do
    {_mod, opts} = plugin(Portal.Oban.NodeSweep)
    assert opts[:minute] in 0..59

    {_mod, cron} = plugin(Oban.Plugins.Cron)
    refute Enum.any?(cron[:crontab], &match?({_e, Portal.Workers.Sweep}, &1))

    # `:maintenance` runs on the web host, which has none of these directories:
    # the sweep would report a clean disk forever while the builders filled up.
    assert Ecto.Changeset.get_field(Portal.Workers.Sweep.new(%{}), :queue) ==
             Portal.NodeQueue.name()
  end

  # No node runs the shared `:ingest` queue any more, so a job put there
  # would wait forever.
  test "no worker defaults to the shared ingest queue" do
    {:ok, modules} = :application.get_key(:portal, :modules)

    workers =
      Enum.filter(modules, fn module ->
        Code.ensure_loaded?(module) and function_exported?(module, :__opts__, 0) and
          function_exported?(module, :perform, 1)
      end)

    assert Portal.Workers.Ingest in workers

    for worker <- workers do
      refute Ecto.Changeset.get_field(worker.new(%{}), :queue) == "ingest", inspect(worker)
    end
  end

  test "request sync is scheduled, on the queue the web host runs" do
    {_mod, opts} = plugin(Oban.Plugins.Cron)

    assert {_expr, Portal.Workers.RequestSync} =
             Enum.find(opts[:crontab], &match?({_e, Portal.Workers.RequestSync}, &1))

    # Rows only, no disks: any node can run it, and the web host's queue keeps
    # it off the build boxes.
    assert Portal.Workers.RequestSync.__opts__()[:queue] == :maintenance
  end

  test "precompiled batch is scheduled every 15 minutes on the maintenance queue" do
    {_mod, opts} = plugin(Oban.Plugins.Cron)

    assert {"*/15 * * * *", Portal.Workers.PrecompiledBatch} =
             Enum.find(opts[:crontab], &match?({_e, Portal.Workers.PrecompiledBatch}, &1))

    # Signing key and rsynced artifact files live on the web host only.
    assert Portal.Workers.PrecompiledBatch.__opts__()[:queue] == :maintenance
  end

  test "the lease reaper is scheduled every five minutes on the maintenance queue" do
    {_mod, opts} = plugin(Oban.Plugins.Cron)

    assert {"*/5 * * * *", Portal.Workers.LeaseReaper} =
             Enum.find(opts[:crontab], &match?({_e, Portal.Workers.LeaseReaper}, &1))

    # Rows only, like `RequestSync`: the web host's queue keeps it off the build boxes.
    assert Portal.Workers.LeaseReaper.__opts__()[:queue] == :maintenance
  end

  test "release downloads refresh weekly, on the queue the web host runs" do
    {_mod, opts} = plugin(Oban.Plugins.Cron)

    assert {expr, Portal.Workers.ReleaseDownloadsRefresh} =
             Enum.find(opts[:crontab], &match?({_e, Portal.Workers.ReleaseDownloadsRefresh}, &1))

    # Once a week: minute, hour and day of week fixed, every day of month.
    assert [minute, hour, "*", "*", weekday] = String.split(expr)
    assert {_, ""} = Integer.parse(minute)
    assert {_, ""} = Integer.parse(hour)
    assert {_, ""} = Integer.parse(weekday)

    # Not on top of the package metadata refresh, which talks to the same
    # rate-limited API for about an hour.
    {meta_expr, _} =
      Enum.find(opts[:crontab], &match?({_e, Portal.Workers.HexMetaRefresh}, &1))

    refute expr == meta_expr
    assert Portal.Workers.ReleaseDownloadsRefresh.__opts__()[:queue] == :intake
  end

  # The admin coverage view reads what this stored; computing it asks the
  # Hex registry about every ranked package, so not on every page load.
  test "the coverage report is refreshed hourly, on the queue the web host runs" do
    {_mod, opts} = plugin(Oban.Plugins.Cron)

    assert {expr, Portal.Workers.CoverageRefresh} =
             Enum.find(opts[:crontab], &match?({_e, Portal.Workers.CoverageRefresh}, &1))

    assert [minute, "*", "*", "*", "*"] = String.split(expr)
    assert {_, ""} = Integer.parse(minute)
    assert Portal.Workers.CoverageRefresh.__opts__()[:queue] == :intake
  end

  # Once a day is the closure-drift cap's period: `max_per_run` per run. Its
  # Hex reads go on the web host's HTTP queue, as `CoverageRefresh`'s do, not
  # on the single `:maintenance` slot that signs batches and reaps leases.
  test "closure drift runs once a day, on the web host's HTTP queue" do
    {_mod, opts} = plugin(Oban.Plugins.Cron)

    assert {expr, Portal.Workers.ClosureDrift} =
             Enum.find(opts[:crontab], &match?({_e, Portal.Workers.ClosureDrift}, &1))

    assert [minute, hour, "*", "*", "*"] = String.split(expr)
    assert {_, ""} = Integer.parse(minute)
    assert {_, ""} = Integer.parse(hour)
    assert Portal.Workers.ClosureDrift.__opts__()[:queue] == :intake
  end

  test "the toolchain sweep runs every 15 minutes, on the maintenance queue" do
    {_mod, opts} = plugin(Oban.Plugins.Cron)

    assert {"2,17,32,47 * * * *", Portal.Workers.ToolchainSweep} =
             Enum.find(opts[:crontab], &match?({_e, Portal.Workers.ToolchainSweep}, &1))

    assert Portal.Workers.ToolchainSweep.__opts__()[:queue] == :maintenance
  end

  test "the report requeue sweep runs daily after midnight UTC on the reports queue" do
    {_mod, opts} = plugin(Oban.Plugins.Cron)

    assert {"29 0 * * *", Portal.Workers.ReportRequeueSweep} =
             Enum.find(opts[:crontab], &match?({_e, Portal.Workers.ReportRequeueSweep}, &1))

    assert Portal.Workers.ReportRequeueSweep.__opts__()[:queue] == :reports
  end

  describe "the hex.pm update check" do
    defp update_check_entry do
      {_mod, opts} = plugin(Oban.Plugins.Cron)
      Enum.find(opts[:crontab], &match?({_e, Portal.Workers.UpdateCheck}, &1))
    end

    defp update_check_config, do: Application.get_env(:portal, Portal.Workers.UpdateCheck, [])

    test "is scheduled, on the queue the web host runs" do
      assert {_expr, Portal.Workers.UpdateCheck} = update_check_entry()

      # One HTTP call to hex.pm and a few inserts. Putting a registry-wide check
      # on `:builds` would queue it behind three builds that can run two hours
      # each, on the machine those builds are already saturating.
      assert Portal.Workers.UpdateCheck.__opts__()[:queue] == :intake
    end

    test "ships enabled" do
      # Asserted rather than assumed, because the failure is silent in both
      # directions: shipped off, nothing ever notices a new release and the
      # catalogue quietly ages; shipped on when it should not be, we send
      # somebody else's service traffic they did not agree to. The runtime
      # override (`NCC_UPDATE_CHECK`) exists so neither needs a deploy to fix.
      assert update_check_config()[:enabled]
    end

    test "runs hourly" do
      {expr, _worker} = update_check_entry()

      assert expr =~ ~r/^\d+ \* \* \* \*$/, "expected an hourly schedule, got #{expr}"
    end
  end

  # One warm at a time per host, on the host whose cache missed: two warms
  # renaming into the same cache would race, and a warm taking a `:builds`
  # slot would run on whichever host polled first. Not on the node queue:
  # Oban has no per-worker limit inside a queue, so there two warms could run
  # side by side, each holding an ingest's slot.
  test "the Nerves cache warm runs one at a time, on the build node's own warm queue" do
    queues =
      [queues: [builds: 3, node: 2]]
      |> Portal.NodeQueue.with_queue(:"portal@host-c")
      |> Portal.Workers.WarmNerves.with_local_queue(:"portal@host-c")
      |> Keyword.fetch!(:queues)

    assert queues[:warm_nerves_portal_host_c] == 1
    assert queues[:node_portal_host_c] == 2
    refute Keyword.has_key?(queues, :node)
  end

  # Hourly, at :13, which no other entry uses: rows and a Hex read, on the
  # web host's queue; the runs it queues need Docker and go to the build
  # nodes' `:system_abi` queue, one at a time per node.
  test "the system ABI observer runs hourly on maintenance, its runs on the build nodes" do
    {_mod, opts} = plugin(Oban.Plugins.Cron)

    assert {"13 * * * *", Portal.Workers.SystemAbiObserve} =
             Enum.find(opts[:crontab], &match?({_e, Portal.Workers.SystemAbiObserve}, &1))

    minutes =
      opts[:crontab]
      |> Enum.reject(&match?({_e, Portal.Workers.SystemAbiObserve}, &1))
      |> Enum.map(fn {expr, _worker} -> expr |> String.split() |> hd() end)

    refute Enum.any?(minutes, &(&1 == "13" or String.contains?(&1, "13,") or &1 == "*"))
    assert Portal.Workers.SystemAbiObserve.__opts__()[:queue] == :maintenance
    assert Portal.Workers.SystemAbiBackfill.__opts__()[:queue] == :maintenance
    assert Portal.Workers.SystemAbiRun.__opts__()[:queue] == :system_abi

    queues = Portal.Workers.SystemAbiRun.with_queue(queues: [builds: 3, node: 2])[:queues]
    assert queues[:system_abi] == 1
  end

  test "the catalog seed sweep is scheduled daily on the intake queue" do
    {_mod, opts} = plugin(Oban.Plugins.Cron)

    assert {"11 5 * * *", Portal.Workers.CatalogSeedSweep} =
             Enum.find(opts[:crontab], &match?({_e, Portal.Workers.CatalogSeedSweep}, &1))

    # Hex.pm lookups, not builds: the web host's queue.
    assert Portal.Workers.CatalogSeedSweep.__opts__()[:queue] == :intake
  end

  test "the hex metadata refresh is scheduled weekly on the intake queue" do
    {_mod, opts} = plugin(Oban.Plugins.Cron)

    assert {"53 4 * * 1", Portal.Workers.HexMetaRefresh} =
             Enum.find(opts[:crontab], &match?({_e, Portal.Workers.HexMetaRefresh}, &1))

    # An HTTP sweep of hex.pm: the web host's queue, never the build box.
    assert Portal.Workers.HexMetaRefresh.__opts__()[:queue] == :intake
  end
end
