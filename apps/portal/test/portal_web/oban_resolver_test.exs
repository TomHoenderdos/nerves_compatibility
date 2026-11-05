defmodule PortalWeb.ObanResolverTest do
  # Oban Web shows its Pro-only queue controls (global and rate limits,
  # partitions) for any engine other than Oban.Engines.Basic, and the portal
  # runs Portal.Oban.OwnedAckEngine. Basic cannot apply those limits, and
  # submitting one raises in the dashboard's LiveView. The dashboard does not
  # scale queues at all: the queue limits are each node's runtime config.
  use ExUnit.Case, async: true

  alias PortalWeb.ObanResolver

  test "every dashboard action but scaling a queue is allowed" do
    access = ObanResolver.resolve_access(nil)

    refute Keyword.get(access, :scale_queues, false)

    for action <- [
          :cancel_jobs,
          :delete_jobs,
          :insert_jobs,
          :pause_queues,
          :retry_jobs,
          :stop_queues,
          :update_jobs,
          :pause_crons,
          :update_crons,
          :insert_crons,
          :delete_crons
        ] do
      assert Keyword.fetch!(access, action), "#{action} is not allowed"
    end
  end

  test "the dashboard is mounted with it" do
    route =
      Enum.find(PortalWeb.Router.__routes__(), &(&1.path == "/admin/oban"))

    assert route, "no /admin/oban route"
    {_live, _action, _opts, live_opts} = route.metadata.phoenix_live_view
    assert get_in(live_opts, [:extra, :session]) |> inspect() =~ "PortalWeb.ObanResolver"
  end
end
