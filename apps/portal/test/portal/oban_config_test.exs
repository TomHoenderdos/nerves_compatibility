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

  test "Lifeline rescues only well after a build's own wall clock" do
    {_mod, opts} = plugin(Oban.Plugins.Lifeline)

    # Rescuing is purely time-based. When `rescue_after` sat at exactly
    # `total_timeout_ms/0`, a build running up against its own deadline could be
    # rescued while still executing — a second container and a second
    # multi-gigabyte scratch tree for work already in flight.
    assert opts[:rescue_after] > Builder.total_timeout_ms()

    # The job also spends, outside the container's wall clock, the L2
    # prefetch before it, and the L2 uploads and the Hex cache promotion
    # after it, each under a budget of its own. Rescue must wait out all four.
    assert opts[:rescue_after] >
             Builder.total_timeout_ms() + Prefetch.budget_ms() +
               Promotion.l2_upload_budget_ms() + Compatibility.HexCache.budget_ms()
  end

  test "the sweeper is scheduled, and on a queue the build host actually runs" do
    {_mod, opts} = plugin(Oban.Plugins.Cron)

    assert {_expr, Portal.Workers.Sweep} =
             Enum.find(opts[:crontab], &match?({_e, Portal.Workers.Sweep}, &1))

    # `:maintenance` runs on the web host, which has none of these directories:
    # the sweep would report a clean disk forever while the build host filled up.
    assert Portal.Workers.Sweep.__opts__()[:queue] == :ingest
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
  # slot would run on whichever host polled first.
  test "the Nerves cache warm runs one at a time, on the build node's own queue" do
    queues =
      [queues: [builds: 3, ingest: 2]]
      |> Portal.Workers.Ingest.with_local_queue(:"portal@host-c")
      |> Portal.Workers.WarmNerves.with_local_queue(:"portal@host-c")
      |> Keyword.fetch!(:queues)

    assert queues[:warm_nerves_portal_host_c] == 1
    assert queues[:ingest_portal_host_c] == 2
  end

  test "the hex metadata refresh is scheduled weekly on the intake queue" do
    {_mod, opts} = plugin(Oban.Plugins.Cron)

    assert {"53 4 * * 1", Portal.Workers.HexMetaRefresh} =
             Enum.find(opts[:crontab], &match?({_e, Portal.Workers.HexMetaRefresh}, &1))

    # An HTTP sweep of hex.pm: the web host's queue, never the build box.
    assert Portal.Workers.HexMetaRefresh.__opts__()[:queue] == :intake
  end
end
