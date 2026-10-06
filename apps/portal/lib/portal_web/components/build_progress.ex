defmodule PortalWeb.BuildProgress do
  @moduledoc """
  Where a package's newest build stands: the stage list while it is on its way,
  and why it failed when it did. Fed by `Portal.ScanRequests.package_progress/1`
  and rendered on the package page, which is the only place a build is shown.
  """
  use Phoenix.Component

  import PortalWeb.CoreComponents, only: [icon: 1]

  @stages [
    {:queued, "Queued", "Accepted and scheduled on the builds queue."},
    {:building, "Building firmware", "Compiling per Nerves system in the build container."},
    {:ingesting, "Ingest results", "Persist runs and archive precompiled artifacts."}
  ]

  @stage_order Enum.map(@stages, &elem(&1, 0))

  @doc "Whether `state` is one of the stages a build passes through."
  def staged?(state), do: state in @stage_order

  @doc "The later of two stages, so a live update never moves the list backwards."
  def later_stage(a, b) do
    if Enum.find_index(@stage_order, &(&1 == b)) > Enum.find_index(@stage_order, &(&1 == a)),
      do: b,
      else: a
  end

  attr :progress, :map, required: true

  attr :first_build?, :boolean,
    default: true,
    doc: "false when the package already has results this build would replace"

  def build_progress(assigns) do
    ~H"""
    <div class="space-y-5">
      <div class="flex flex-wrap items-center gap-2">
        <span
          id="request-status"
          class={[
            "rounded-full px-2.5 py-1 text-xs font-semibold ring-1",
            if(@progress.state == :failed,
              do: PortalWeb.UI.status_pill_class("error"),
              else: "bg-base-200 text-base-content/70 ring-base-300"
            )
          ]}
        >
          {label(@progress.state)}
        </span>
        <span :if={@progress.version} class="font-mono text-xs text-base-content/50">
          {@progress.version}
        </span>
      </div>
      <p class="text-sm text-base-content/70">{explanation(@progress.state, @first_build?)}</p>

      <%!-- A request waiting for review has not been scheduled, so it has no
      stages yet; a failed one replaces the list with the reason it stopped. --%>
      <ol :if={staged?(@progress.state)} id="build-stages" class="space-y-4">
        <li
          :for={{key, label, desc} <- stages()}
          id={"build-stage-#{key}"}
          data-state={stage_state(key, @progress.state)}
          class={[
            "flex items-start gap-3",
            stage_state(key, @progress.state) == :pending && "opacity-40"
          ]}
        >
          <span class={[
            "mt-0.5 flex h-6 w-6 shrink-0 items-center justify-center rounded-full",
            stage_state(key, @progress.state) == :done && "bg-emerald-500 text-white",
            stage_state(key, @progress.state) == :active && "bg-primary text-primary-content",
            stage_state(key, @progress.state) == :pending &&
              "border-2 border-base-300 text-base-content/40"
          ]}>
            <.icon
              :if={stage_state(key, @progress.state) == :done}
              name="hero-check-mini"
              class="size-3.5"
            />
            <span
              :if={stage_state(key, @progress.state) == :active}
              class="h-2 w-2 animate-pulse rounded-full bg-current"
            >
            </span>
          </span>
          <div>
            <div class="font-medium text-base-content">{label}</div>
            <div class="text-sm text-base-content/60">{desc}</div>
          </div>
        </li>
      </ol>

      <%!-- A failure can arrive with a reason and no log (a crash before the
      runner wrote one), so each part shows on its own. --%>
      <div
        :if={@progress.state == :failed and (@progress.error_reason || @progress.error_log)}
        id="request-failure"
        class="overflow-hidden rounded-xl border border-error/40 bg-base-300/30"
      >
        <div
          :if={@progress.error_reason}
          id="request-error-reason"
          class="border-b border-base-300 px-4 py-2.5 font-mono text-xs text-base-content/60"
        >
          build failed: {@progress.error_reason}
        </div>
        <div
          :if={@progress.summary}
          id="request-failure-summary"
          class="border-b border-base-300 bg-error/5 px-4 py-3"
        >
          <div class="text-xs font-semibold uppercase tracking-wide text-error">
            Why it failed
          </div>
          <pre class="mt-1 overflow-x-auto font-mono text-xs leading-relaxed text-base-content">{@progress.summary}</pre>
        </div>
        <%!-- The cause of a failure is at the end of the log, so the scroller is
        reversed: a column-reverse flex box starts scrolled to its bottom. --%>
        <div :if={@progress.error_log} id="request-error-log">
          <div data-starts-at-end class="flex max-h-96 flex-col-reverse overflow-auto">
            <pre class="p-4 font-mono text-xs leading-relaxed text-base-content/80">{@progress.error_log}</pre>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp stages, do: @stages

  defp stage_state(key, current) do
    position = Enum.find_index(@stage_order, &(&1 == key))
    current_position = Enum.find_index(@stage_order, &(&1 == current))

    cond do
      position < current_position -> :done
      position == current_position -> :active
      true -> :pending
    end
  end

  defp label(:review), do: "Waiting for review"
  defp label(:queued), do: "Queued"
  defp label(:building), do: "Building"
  defp label(:ingesting), do: "Ingesting results"
  defp label(:failed), do: "Build failed"

  defp explanation(:review, _first_build?),
    do: "Requests made without verifying ownership are read by an admin before they are built."

  defp explanation(:queued, true),
    do: "It is in the build queue. Its results appear here once the first build finishes."

  defp explanation(:queued, false),
    do: "A new build is in the queue. Its results replace these when it finishes."

  defp explanation(state, true) when state in [:building, :ingesting],
    do: "Its firmware is being built right now. Results appear here when it finishes."

  defp explanation(state, false) when state in [:building, :ingesting],
    do: "A new build is running. Its results replace these when it finishes."

  defp explanation(:failed, true),
    do: "The first build did not produce a result, so there is nothing to show yet."

  defp explanation(:failed, false),
    do:
      "The newest build did not produce a result. The results below are from the last one that did."
end
