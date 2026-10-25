defmodule PortalWeb.Builder.JobController do
  @moduledoc """
  The remote job API on `PortalWeb.BuilderEndpoint`, behind
  `PortalWeb.Plugs.BuilderCert`: the claim long-poll, the lease heartbeat,
  the upload of a run's files (`files/missing`, verified tar batches) and its
  completion.
  """
  use PortalWeb, :controller

  require Logger

  alias Portal.Builders
  alias Portal.Builders.{Images, Leases, RateLimit, Upload, WarmAllowlist}
  alias Portal.Workers.{Ingest, Progress}

  @claims_per_minute 60
  @read_opts [length: 1_048_576, read_length: 262_144, read_timeout: 60_000]

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

  def missing(conn, %{"lease_id" => id} = params) do
    with {:ok, lease} <- Leases.held(id, conn.assigns.builder.id),
         {:ok, missing} <- Upload.missing(lease.id, Map.get(params, "shas", [])) do
      json(conn, %{missing: missing})
    else
      {:error, :not_held} -> error(conn, 409, "lease_not_held")
      {:error, :too_many} -> error(conn, 422, "too_many_files")
      {:error, :invalid_sha} -> error(conn, 422, "invalid_sha")
    end
  end

  def files(conn, %{"lease_id" => id}) do
    with {:ok, lease} <- Leases.held(id, conn.assigns.builder.id),
         {:ok, length} <- content_length(conn),
         {:ok, lease} <- Leases.heartbeat(lease.id, lease.builder_id, "uploading", nil) do
      reader = body_reader(conn)
      result = Upload.receive_batch(lease, reader.read, content_length: length)
      files_response(reader.conn.(), result)
    else
      {:error, :not_held} -> error(conn, 409, "lease_not_held")
      {:error, :missing_content_length} -> error(conn, 400, "missing_content_length")
      {:error, :update_failed} -> error(conn, 500, "heartbeat_failed")
    end
  end

  defp files_response(conn, {:ok, %{bad: []} = summary}), do: json(conn, summary)

  defp files_response(conn, {:ok, summary}) do
    conn
    |> put_status(422)
    |> json(%{
      error: "bad_entries",
      bad: summary.bad,
      stored: summary.stored,
      bytes: summary.bytes
    })
  end

  defp files_response(conn, {:error, reason}) do
    case reason do
      :batch_too_large -> error(conn, 413, "batch_too_large")
      :total_exceeded -> error(conn, 413, "total_exceeded")
      :insufficient_disk -> error(conn, 507, "insufficient_disk")
      :not_held -> error(conn, 409, "lease_not_held")
      {:unsupported_entry, _name} -> error(conn, 400, "unsupported_entry")
      :truncated -> error(conn, 400, "truncated")
      _ -> error(conn, 400, "bad_body")
    end
  end

  # `Plug.Conn.read_body/2` returns a new conn each time; keep the latest in
  # the process so the response goes out on the conn that finished reading.
  defp body_reader(conn) do
    Process.put(:ncc_upload_conn, conn)

    %{
      read: fn ->
        case Plug.Conn.read_body(Process.get(:ncc_upload_conn), @read_opts) do
          {:ok, chunk, conn} ->
            Process.put(:ncc_upload_conn, conn)
            {:ok, chunk}

          {:more, chunk, conn} ->
            Process.put(:ncc_upload_conn, conn)
            {:more, chunk}

          {:error, reason} ->
            {:error, reason}
        end
      end,
      conn: fn -> Process.delete(:ncc_upload_conn) end
    }
  end

  defp content_length(conn) do
    with [value] <- get_req_header(conn, "content-length"),
         {n, ""} when n >= 0 <- Integer.parse(value) do
      {:ok, n}
    else
      _ -> {:error, :missing_content_length}
    end
  end

  def complete(conn, %{"lease_id" => id} = params) do
    builder = conn.assigns.builder

    with {:ok, lease} <- Leases.held(id, builder.id),
         {:ok, exit_code} <- exit_code(params["exit_code"]),
         {:ok, lease} <- Leases.heartbeat(lease.id, lease.builder_id, "uploading", nil),
         :ok <- write_outputs(lease, exit_code, params),
         {:ok, outcome, lease} <- end_attempt(lease, exit_code, builder) do
      if outcome == :done do
        Progress.broadcast(lease.scan_request_id, :ingesting, %{run_id: lease.run_id})
      else
        Upload.cleanup(lease.id)
      end

      conn |> put_status(202) |> json(%{accepted: true, outcome: outcome})
    else
      {:error, :not_held} -> error(conn, 409, "lease_not_held")
      {:error, :update_failed} -> error(conn, 500, "complete_failed")
      {:error, :ingest_not_enqueued} -> error(conn, 500, "complete_failed")
      {:error, :bad_exit_code} -> error(conn, 400, "bad_exit_code")
      {:error, :result_unparsable} -> error(conn, 422, "result_unparsable")
      {:error, :result_too_large} -> error(conn, 413, "result_too_large")
      {:error, :logs_too_large} -> error(conn, 413, "logs_too_large")
      {:error, :logs_invalid} -> error(conn, 422, "logs_invalid")
    end
  end

  # A done lease and its Ingest job commit together: if the enqueue fails the
  # lease stays held and the agent's retry of `complete` lands again.
  defp end_attempt(lease, 0, builder) do
    args = %{
      "source" => "remote",
      "lease_id" => lease.id,
      "run_id" => lease.run_id,
      "image_digest" => lease.image_digest,
      "scan_request_id" => lease.scan_request_id,
      "builder_id" => builder.id
    }

    Portal.Repo.transaction(fn ->
      with {:ok, :done, lease} <- Leases.complete(lease, 0),
           {:ok, _job} <- args |> Ingest.new(queue: :remote) |> Oban.insert() do
        {:done, lease}
      else
        {:error, reason} when reason in [:not_held, :update_failed] ->
          Portal.Repo.rollback(reason)

        {:error, reason} ->
          Logger.error("could not enqueue remote ingest for #{lease.id}: #{inspect(reason)}")
          Portal.Repo.rollback(:ingest_not_enqueued)
      end
    end)
    |> case do
      {:ok, {:done, lease}} -> {:ok, :done, lease}
      {:error, reason} -> {:error, reason}
    end
  end

  defp end_attempt(lease, exit_code, _builder), do: Leases.complete(lease, exit_code)

  # A failing exit needs no result.json; a success needs one.
  defp write_outputs(_lease, exit_code, _params) when exit_code != 0, do: :ok

  defp write_outputs(lease, 0, %{"result" => %Plug.Upload{} = result} = params) do
    Upload.write_outputs(lease.id, %{
      result: result,
      logs: upload(params["logs"]),
      runner_log: upload(params["runner_log"])
    })
  end

  defp write_outputs(_lease, 0, _params), do: {:error, :result_unparsable}

  defp upload(%Plug.Upload{} = upload), do: upload
  defp upload(_), do: nil

  defp exit_code(code) when is_integer(code) and code >= 0, do: {:ok, code}

  defp exit_code(code) when is_binary(code) do
    case Integer.parse(code) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> {:error, :bad_exit_code}
    end
  end

  defp exit_code(_), do: {:error, :bad_exit_code}

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
