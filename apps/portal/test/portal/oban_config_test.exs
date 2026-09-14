defmodule Portal.ObanConfigTest do
  @moduledoc """
  Guards two Oban settings whose only failure mode is silent and expensive.
  """
  use ExUnit.Case, async: true

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
  end

  test "the sweeper is scheduled, and on a queue the build host actually runs" do
    {_mod, opts} = plugin(Oban.Plugins.Cron)

    assert {_expr, Portal.Workers.Sweep} =
             Enum.find(opts[:crontab], &match?({_e, Portal.Workers.Sweep}, &1))

    # `:maintenance` runs on the web host, which has none of these directories:
    # the sweep would report a clean disk forever while the build host filled up.
    assert Portal.Workers.Sweep.__opts__()[:queue] == :ingest
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

    test "runs hourly, with a cap on what one run may queue" do
      {expr, _worker} = update_check_entry()

      assert expr =~ ~r/^\d+ \* \* \* \*$/, "expected an hourly schedule, got #{expr}"

      # Each run diffs the whole registry, so there is no window to keep wider
      # than the interval and a missed tick loses nothing. What the schedule
      # does need is the cap: without one, the first run after a quiet spell
      # hands the build host the entire backlog at once.
      assert update_check_config()[:max_per_run] > 0
    end
  end
end
