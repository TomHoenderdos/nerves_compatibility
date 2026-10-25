defmodule PortalWeb.Builder.JobController do
  @moduledoc """
  The remote job API on `PortalWeb.BuilderEndpoint`, behind
  `PortalWeb.Plugs.BuilderCert`: the claim long-poll and the lease
  heartbeat.
  """
  use PortalWeb, :controller

  require Logger

  alias Portal.Builders
  alias Portal.Builders.{Images, Leases, RateLimit, WarmAllowlist}

  @claims_per_minute 60

  def claim(conn, params) do
    builder = conn.assigns.builder

    cond do
      not RateLimit.allow?({:claim, builder.id}, @claims_per_minute, :timer.minutes(1)) ->
        error(conn, 429, "rate_limited")

      # Without its egress ruleset a builder's containers could reach anything,
      # so it gets no work until the ruleset is back.
      params["egress"] != "ok" ->
        record_egress(builder, "missing")
        error(conn, 409, "egress_missing")

      free_slots(params) < 1 ->
        send_resp(conn, 204, "")

      true ->
        record_egress(builder, "ok")

        case Leases.claim_or_wait(builder, Leases.long_poll_ms()) do
          :none -> send_resp(conn, 204, "")
          {:ok, lease} -> json(conn, claim_body(lease))
        end
    end
  end

  def heartbeat(conn, %{"lease_id" => id} = params) do
    case Leases.heartbeat(id, conn.assigns.builder.id, params["phase"], params["log_tail"]) do
      {:ok, _lease} -> json(conn, %{ok: true})
      {:error, :not_held} -> error(conn, 409, "lease_not_held")
      {:error, :update_failed} -> error(conn, 500, "heartbeat_failed")
    end
  end

  defp claim_body(lease) do
    input =
      Portal.Builder.worker_input(%{
        run_id: lease.run_id,
        image_name: lease.image_name,
        image_digest: lease.image_digest,
        package: %{"name" => lease.package, "version" => lease.version, "source" => "hex"},
        systems_filter: lease.args["systems_filter"],
        mode: lease.args["mode"],
        argus: lease.args["argus"]
      })

    agent = Images.agent()

    %{
      lease_id: lease.id,
      run_id: lease.run_id,
      image: %{name: lease.image_name, digest: lease.image_digest},
      input: input,
      timeout_sec: div(Portal.Builder.total_timeout_ms(), 1000),
      upload: Leases.upload_caps(),
      min_agent_version: agent && agent.version,
      agent_releases: (agent && agent.releases) || %{},
      warm_allowlist: WarmAllowlist.names(),
      egress_required: true
    }
  end

  # A claim arrives every few seconds per slot; write the row only on change.
  # Bookkeeping for the admin page: a failed write is logged, and the claim
  # is answered on the egress the agent reported either way.
  defp record_egress(%{egress_status: status}, status), do: :ok

  defp record_egress(builder, status) do
    case Builders.set_egress(builder, status) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "could not record egress #{status} for #{builder.name}: #{inspect(reason)}"
        )
    end
  end

  defp free_slots(%{"free_slots" => n}) when is_integer(n), do: n
  defp free_slots(_), do: 1

  defp error(conn, status, reason), do: conn |> put_status(status) |> json(%{error: reason})
end
