defmodule PortalWeb.RequestLive do
  use PortalWeb, :live_view

  alias Portal.ScanRequests

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Portal.PubSub, "request:#{id}")

    case ScanRequests.get_request(id) do
      {:ok, request} ->
        {:ok,
         socket
         |> assign(:page_title, "Scan request")
         |> assign(:page_description, "Live progress of a requested Nerves compatibility build.")
         |> assign(:id, id)
         |> assign(:request, request)
         |> assign(:stage, nil)
         |> assign(:payload, %{})}

      {:error, _reason} ->
        {:ok,
         socket
         |> put_flash(:error, "Request not found")
         |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def handle_info({:build_progress, stage, payload}, socket) do
    request =
      case ScanRequests.get_request(socket.assigns.id) do
        {:ok, request} -> request
        {:error, _reason} -> socket.assigns.request
      end

    {:noreply,
     socket
     |> assign(:request, request)
     |> assign(:stage, stage)
     |> assign(:payload, payload || %{})}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:request_scan} current_user={@current_user}>
      <section class="space-y-7">
        <a
          href={~p"/packages"}
          class="inline-flex items-center gap-1.5 text-sm font-medium text-base-content/60 transition hover:text-base-content"
        >
          <.icon name="hero-chevron-left-mini" class="size-4" /> All packages
        </a>

        <PortalWeb.UI.page_header kicker="Scan request" title={@request.package_name}>
          <:subtitle><span class="font-mono text-sm">{@request.id}</span></:subtitle>
        </PortalWeb.UI.page_header>

        <div class="grid grid-cols-3 gap-3">
          <div class="rounded-2xl border border-base-300 bg-base-100 p-5 shadow-sm">
            <div class="text-sm text-base-content/60">Status</div>
            <div id="request-status" class="mt-1 text-lg font-semibold text-primary">
              {@request.status}
            </div>
          </div>
          <PortalWeb.UI.stat_card label="Version" value={@request.version || "latest"} />
          <PortalWeb.UI.stat_card label="Source" value={to_string(@request.source)} />
        </div>

        <div class="rounded-2xl border border-base-300 bg-base-100 p-6 shadow-sm">
          <h2 class="text-sm font-semibold uppercase tracking-wider text-base-content/60">
            Build progress
          </h2>
          <ol class="mt-5 space-y-5">
            <li
              :for={{_key, label, desc, state} <- stage_items(assigns)}
              class={[
                "flex items-start gap-3",
                state == :pending && "opacity-40"
              ]}
            >
              <span class={[
                "mt-0.5 flex h-6 w-6 shrink-0 items-center justify-center rounded-full",
                state == :done && "bg-emerald-500 text-white",
                state == :active && "bg-primary text-primary-content",
                state == :pending && "border-2 border-base-300 text-base-content/40"
              ]}>
                <.icon :if={state == :done} name="hero-check-mini" class="size-3.5" />
                <span :if={state == :active} class="h-2 w-2 animate-pulse rounded-full bg-current">
                </span>
              </span>
              <div>
                <div class="font-medium text-base-content">{label}</div>
                <div class="text-sm text-base-content/60">{desc}</div>
              </div>
            </li>
          </ol>
        </div>

        <div
          :if={@request.error_log}
          id="request-error-log"
          class="overflow-hidden rounded-2xl border border-error/40 bg-base-300/30 shadow-sm"
        >
          <div class="border-b border-base-300 px-4 py-2.5 font-mono text-xs text-base-content/60">
            build failed: {@request.error_reason}
          </div>
          <pre class="max-h-96 overflow-auto p-4 font-mono text-xs leading-relaxed text-base-content/80">{@request.error_log}</pre>
        </div>

        <div
          :if={map_size(@payload) > 0}
          class="overflow-hidden rounded-2xl border border-base-300 bg-base-300/30 shadow-sm"
        >
          <div class="border-b border-base-300 px-4 py-2.5 font-mono text-xs text-base-content/60">
            latest progress
          </div>
          <pre class="overflow-auto p-4 font-mono text-xs leading-relaxed text-base-content/80">{inspect(@payload, pretty: true)}</pre>
        </div>
      </section>
    </Layouts.app>
    """
  end

  defp stages do
    [
      {:queued, "Queued", "Accepted and scheduled on the builds queue."},
      {:building, "Building firmware", "Compiling per Nerves system in the build container."},
      {:ingesting, "Ingest results", "Persist runs and archive precompiled artifacts."}
    ]
  end

  defp stage_items(assigns) do
    Enum.map(stages(), fn {key, label, desc} -> {key, label, desc, stage_state(key, assigns)} end)
  end

  # Map the request status + live stage onto a tri-state per stage.
  # Terminal requests (finished, one way or another) show every stage as done
  # instead of leaving the final stage pulsing as :active.
  defp stage_state(key, %{request: request, stage: stage}) do
    if terminal?(request.status) do
      :done
    else
      order = [:queued, :building, :ingesting]
      current = current_stage(request.status, stage)

      cond do
        Enum.find_index(order, &(&1 == key)) < Enum.find_index(order, &(&1 == current)) -> :done
        key == current -> :active
        true -> :pending
      end
    end
  end

  # Status enum: :pending, :accepted, :queued, :built, :rejected, :error
  defp terminal?(status), do: to_string(status) in ["built", "rejected", "error"]

  defp current_stage(status, stage) do
    status = to_string(status)
    stage = to_string(stage)

    cond do
      status in ["built", "rejected", "error"] -> :ingesting
      stage =~ "ingest" -> :ingesting
      stage =~ "build" -> :building
      true -> :queued
    end
  end
end
