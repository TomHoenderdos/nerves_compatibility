defmodule Portal.ScanRequests do
  @moduledoc """
  Ash domain for package scan request state.
  """

  use Ash.Domain
  import Ash.Expr
  require Ash.Query

  resources do
    resource(Portal.ScanRequests.ScanRequest)
  end

  alias Portal.ScanRequests.ScanRequest
  alias Portal.Workers.Build

  def pending_anonymous_requests do
    ScanRequest
    |> Ash.Query.filter(expr(source == :anonymous_manual and status == :pending))
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.read!(domain: __MODULE__)
  end

  def queue_requests do
    ScanRequest
    |> Ash.Query.filter(expr(status in [:accepted, :queued]))
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.read!(domain: __MODULE__)
  end

  def create_once(attrs) when is_map(attrs) do
    package_name = Map.fetch!(attrs, :package_name)
    requested_status = Map.get(attrs, :status, :accepted)

    request_result =
      case open_request_for_package(package_name) do
        nil ->
          create_request(attrs)

        %ScanRequest{status: :pending} = request when requested_status in [:accepted, :queued] ->
          replace_open_request(request, attrs)

        %ScanRequest{} = request ->
          {:ok, request}
      end

    maybe_enqueue_accepted(request_result, requested_status)
  end

  def open_request_for_package(package_name) when is_binary(package_name) do
    ScanRequest
    |> Ash.Query.filter(
      expr(package_name == ^package_name and status in [:pending, :accepted, :queued])
    )
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.read!(domain: __MODULE__)
    |> List.first()
  end

  def approve_anonymous_request(id, admin_user) do
    with {:ok, request} <- get_request(id),
         :ok <- ensure_pending_anonymous(request),
         {:ok, request} <- update_review(request, :accepted, nil),
         {:ok, request} <- enqueue_build(request, :anonymous_manual, admin_user) do
      {:ok, request}
    end
  end

  def reject_anonymous_request(id, admin_user) do
    with {:ok, request} <- get_request(id),
         :ok <- ensure_pending_anonymous(request),
         {:ok, request} <- update_review(request, :rejected, "Rejected by #{admin_user.username}") do
      {:ok, request}
    end
  end

  # This used to read every row and filter in Elixir. It is called from
  # `RequestLive.mount/3` on a public route, again on every progress broadcast,
  # and up to four times per build from `Progress.mark/3` — against a table that
  # grows one row per Hex release discovered across the catalog, and whose rows
  # now carry up to 16 KB of `error_log` each.
  #
  # The id comes straight off `/requests/:id`, so it is not necessarily a UUID.
  # Ash turns an uncastable filter value into an `InvalidFilterValue` error and,
  # inside a transaction, into a rollback throw, where the old full scan simply
  # found nothing — so the shape is checked before the query is built.
  def get_request(id) when is_binary(id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         {:ok, %ScanRequest{} = request} <-
           ScanRequest
           |> Ash.Query.filter(expr(id == ^uuid))
           |> Ash.read_one(domain: __MODULE__) do
      {:ok, request}
    else
      :error -> {:error, :not_found}
      {:ok, nil} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def get_request(_id), do: {:error, :not_found}

  @doc """
  Update a request's lifecycle status (and optionally error_reason / error_log / run_id).
  Used by the Build worker to mark requests built/rejected/error.
  """
  def set_status(request_or_id, status, opts \\ [])

  def set_status(%ScanRequest{} = request, status, opts) do
    request
    |> Ash.Changeset.for_update(:set_status, %{
      status: status,
      error_reason: Keyword.get(opts, :error_reason),
      error_log: Keyword.get(opts, :error_log),
      run_id: Keyword.get(opts, :run_id)
    })
    |> Ash.update(domain: __MODULE__)
  end

  def set_status(id, status, opts) when is_binary(id) do
    with {:ok, request} <- get_request(id) do
      set_status(request, status, opts)
    end
  end

  defp create_request(attrs) do
    ScanRequest
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create(domain: __MODULE__)
  end

  defp replace_open_request(request, attrs) do
    request
    |> Ash.Changeset.for_update(:replace_open_request, %{
      source: Map.fetch!(attrs, :source),
      status: Map.get(attrs, :status, :accepted),
      user_id: Map.get(attrs, :user_id),
      subject: Map.get(attrs, :subject),
      verification_provider: Map.get(attrs, :verification_provider),
      error_reason: Map.get(attrs, :error_reason)
    })
    |> Ash.update(domain: __MODULE__)
  end

  defp ensure_pending_anonymous(%ScanRequest{source: :anonymous_manual, status: :pending}),
    do: :ok

  defp ensure_pending_anonymous(_request), do: {:error, :not_pending_anonymous}

  defp update_review(request, status, error_reason) do
    request
    |> Ash.Changeset.for_update(:review, %{
      status: status,
      error_reason: error_reason
    })
    |> Ash.update(domain: __MODULE__)
  end

  defp maybe_enqueue_accepted({:ok, %ScanRequest{} = request}, requested_status)
       when requested_status in [:accepted, :queued] do
    enqueue_build(request, request.source)
  end

  defp maybe_enqueue_accepted(result, _requested_status), do: result

  defp enqueue_build(%ScanRequest{} = request, source, admin_user \\ nil) do
    case version_resolver().latest_version(request.package_name) do
      {:ok, version} ->
        with {:ok, _job} <- insert_build_job(request, version, source),
             {:ok, request} <- set_status(request, :queued) do
          maybe_mark_admin_approval(request, admin_user)
        end

      {:error, reason} when reason in [:unknown_package, :unknown_package_version] ->
        # The row is committed before we ever ask hex whether the package
        # exists, and `open_request_for_package/1` matches only open statuses.
        # Leaving it `:accepted` stranded it there for good: the caller's
        # `{:cancel, reason}` tidied up the job but not the row, and every later
        # request for the same name short-circuited to the dead one and was
        # never scanned. Close it out here instead.
        _ = set_status(request, :rejected, error_reason: "package not found on hex.pm")
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp insert_build_job(request, version, source) do
    %{package: request.package_name, version: version, scan_request_id: request.id}
    |> Build.new(priority: priority(source))
    |> Oban.insert()
  end

  defp priority(:hex_owner), do: 0
  defp priority(:github_repo), do: 1
  defp priority(:anonymous_turnstile), do: 3
  defp priority(:anonymous_manual), do: 3
  # A sweep of the whole upstream catalogue must never delay a real request, so
  # it takes the lowest priority Oban offers.
  defp priority(:backfill), do: 9
  defp priority(_source), do: 6

  defp version_resolver do
    Application.get_env(:portal, :package_version_resolver, Portal.HexPm)
  end

  defp maybe_mark_admin_approval(request, nil), do: {:ok, request}

  defp maybe_mark_admin_approval(request, admin_user) do
    request
    |> Ash.Changeset.for_update(:replace_open_request, %{
      source: :anonymous_manual,
      status: :queued,
      user_id: request.user_id,
      subject: "approved_by:#{admin_user.username}",
      verification_provider: "manual_admin_review",
      error_reason: nil
    })
    |> Ash.update(domain: __MODULE__)
  end
end
