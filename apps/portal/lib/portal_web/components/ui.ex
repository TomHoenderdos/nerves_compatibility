defmodule PortalWeb.UI do
  @moduledoc "Beacon design-system components shared across LiveViews and controller pages."
  use Phoenix.Component

  @doc "Section header: optional kicker, title, optional subtitle and actions slots."
  attr :kicker, :string, default: nil
  attr :title, :string, required: true
  attr :class, :any, default: nil
  slot :subtitle
  slot :actions

  def page_header(assigns) do
    ~H"""
    <div class={["flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between", @class]}>
      <div class="space-y-2">
        <p :if={@kicker} class="text-xs font-semibold uppercase tracking-[0.25em] text-primary">
          {@kicker}
        </p>
        <h1 class="text-3xl font-bold tracking-tight text-base-content sm:text-4xl">{@title}</h1>
        <div :if={@subtitle != []} class="max-w-2xl text-base-content/70">
          {render_slot(@subtitle)}
        </div>
      </div>
      <div :if={@actions != []} class="shrink-0">{render_slot(@actions)}</div>
    </div>
    """
  end

  @doc "A labelled value tile."
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :accent, :string, default: nil

  def stat_card(assigns) do
    ~H"""
    <div class="rounded-2xl border border-base-300 bg-base-100 p-5 shadow-sm">
      <div class="text-sm text-base-content/60">{@label}</div>
      <div class={[
        "mt-1 text-2xl font-bold tracking-tight",
        @accent == "pass" && "text-emerald-600 dark:text-emerald-400",
        @accent == "primary" && "text-primary",
        is_nil(@accent) && "text-base-content"
      ]}>
        {@value}
      </div>
    </div>
    """
  end

  @doc "Status pill. Text is the status string."
  attr :status, :string, required: true
  attr :class, :any, default: nil

  def status_badge(assigns) do
    ~H"""
    <span class={[
      "rounded-full px-2.5 py-1 text-xs text-center font-semibold ring-1",
      status_pill_class(@status),
      @class
    ]}>
      {@status}
    </span>
    """
  end

  @doc "Row of per-system colored segments."
  attr :statuses, :list, required: true

  def system_bar(assigns) do
    ~H"""
    <div class="flex gap-1">
      <span :for={s <- @statuses} class={["h-2 w-6 rounded-full", status_segment_class(s)]} title={s}>
      </span>
    </div>
    """
  end

  @doc "Package summary card for the browser grid."
  attr :name, :string, required: true
  attr :description, :string, default: nil
  attr :version, :string, default: nil
  attr :href, :string, required: true
  attr :summary, :string, default: nil
  attr :summary_status, :string, default: "unknown"
  attr :statuses, :list, default: []
  attr :rest, :global

  def package_card(assigns) do
    ~H"""
    <a
      href={@href}
      class="group rounded-2xl border border-base-300 bg-base-100 p-5 shadow-sm transition hover:-translate-y-0.5 hover:border-base-content/20 hover:shadow-md"
      {@rest}
    >
      <div class="flex items-start justify-between gap-4">
        <div class="min-w-0">
          <h2 class="truncate text-base font-semibold text-base-content group-hover:text-primary">
            {@name}
          </h2>
          <p class="mt-1 line-clamp-2 text-sm text-base-content/60">
            {@description || "No description"}
          </p>
        </div>
        <.status_badge :if={@summary} status={@summary} class={summary_override(@summary_status)} />
      </div>
      <div class="mt-4 flex items-center justify-between text-xs text-base-content/50">
        <span class="font-mono">{@version || "—"}</span>
        <.system_bar :if={@statuses != []} statuses={@statuses} />
      </div>
    </a>
    """
  end

  # The pill text is a summary ("4/6 pass") but its color should follow the worst status.
  defp summary_override(status), do: status_pill_class(status)

  @doc "Tailwind classes for a status pill (theme-aware)."
  def status_pill_class("pass"),
    do:
      "bg-emerald-50 text-emerald-700 ring-emerald-100 dark:bg-emerald-500/10 dark:text-emerald-300 dark:ring-emerald-500/20"

  def status_pill_class("fail"),
    do:
      "bg-orange-50 text-orange-700 ring-orange-100 dark:bg-orange-500/10 dark:text-orange-300 dark:ring-orange-500/20"

  def status_pill_class("error"),
    do:
      "bg-red-50 text-red-700 ring-red-100 dark:bg-red-500/10 dark:text-red-300 dark:ring-red-500/20"

  def status_pill_class("skipped"),
    do:
      "bg-base-200 text-base-content/60 ring-base-300 dark:bg-base-200 dark:text-base-content/60 dark:ring-base-300"

  def status_pill_class(_),
    do:
      "bg-amber-50 text-amber-700 ring-amber-100 dark:bg-amber-500/10 dark:text-amber-300 dark:ring-amber-500/20"

  @doc "Tailwind background classes for a system_bar segment (theme-aware)."
  def status_segment_class("pass"), do: "bg-emerald-400 dark:bg-emerald-500"
  def status_segment_class("fail"), do: "bg-orange-400 dark:bg-orange-500"
  def status_segment_class("error"), do: "bg-red-400 dark:bg-red-500"
  def status_segment_class(_), do: "bg-base-300"
end
