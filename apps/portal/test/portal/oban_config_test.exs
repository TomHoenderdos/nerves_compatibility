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

    test "ships disabled" do
      # This polls somebody else's service on a schedule. It stays off until
      # hex.pm has agreed to the traffic, and `NCC_UPDATE_CHECK=1` is what turns
      # it on -- no code change, so the answer can be acted on the same day.
      refute update_check_config()[:enabled]
    end

    test "the lookback window is wider than the interval it runs on" do
      {expr, _worker} = update_check_entry()

      # There is no stored watermark: overlapping windows are the only thing
      # making a missed tick harmless. A window at or below the interval
      # silently loses every update that lands in a run that did not happen.
      assert expr =~ ~r/^\d+ \* \* \* \*$/, "expected an hourly schedule, got #{expr}"
      assert update_check_config()[:lookback_ms] >= :timer.hours(2)
    end
  end
end
