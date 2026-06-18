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

    case open_request_for_package(package_name) do
      nil ->
        create_request(attrs)

      %ScanRequest{status: :pending} = request when requested_status in [:accepted, :queued] ->
        replace_open_request(request, attrs)

      %ScanRequest{} = request ->
        {:ok, request}
    end
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
         {:ok, request} <- update_review(request, :accepted, nil) do
      forward_to_orchestrator(request, admin_user)
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

  def get_request(id) when is_binary(id) do
    with {:ok, requests} <- Ash.read(ScanRequest, domain: __MODULE__),
         %ScanRequest{} = request <- Enum.find(requests, &(&1.id == id)) do
      {:ok, request}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def get_request(_id), do: {:error, :not_found}

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

  defp forward_to_orchestrator(request, admin_user) do
    url = Application.get_env(:portal, :orchestrator_scan_request_url)
    secret = Application.get_env(:portal, :scan_request_shared_secret)

    if is_binary(url) and url != "" and is_binary(secret) and secret != "" do
      Req.post(url,
        headers: [
          {"content-type", "application/json"},
          {"authorization", "Bearer #{secret}"}
        ],
        json: %{
          package: request.package_name,
          source: "anonymous_manual",
          verified: true,
          verification_provider: "manual_admin_review",
          subject: "approved_by:#{admin_user.username}"
        }
      )
    end
  end
end
