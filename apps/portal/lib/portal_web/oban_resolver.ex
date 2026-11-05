defmodule PortalWeb.ObanResolver do
  @moduledoc """
  The Oban Web dashboard's access at `/admin/oban`: everything an admin
  could do before, except scaling a queue.

  Oban Web decides whether Oban Pro is missing by the engine module alone
  and shows its Pro-only queue controls (global limits, rate limits,
  partitions) for any engine but `Oban.Engines.Basic`. The portal runs
  `Portal.Oban.OwnedAckEngine`, which is Basic with guarded acks and cannot
  apply those limits: submitting one raises in the dashboard's LiveView.
  Scaling access covers the local limit as well, which is ephemeral here:
  each node's queue limits are its runtime config, and `bin/portal rpc
  "Oban.scale_queue(...)"` still changes one live.
  """

  @behaviour Oban.Web.Resolver

  @impl true
  def resolve_access(_user) do
    [
      cancel_jobs: true,
      cancel_workflows: true,
      delete_crons: true,
      delete_jobs: true,
      insert_crons: true,
      insert_jobs: true,
      pause_crons: true,
      pause_queues: true,
      retry_jobs: true,
      retry_workflows: true,
      scale_queues: false,
      stop_queues: true,
      update_crons: true,
      update_jobs: true
    ]
  end
end
