defmodule PortalWeb.Admin.MaintenanceLive do
  @moduledoc """
  Admin Maintenance tab: the hex.pm update check, bulk rebuilds with their
  sweeps in a Cinder table, precompiled signing and the toolchain backlog.

  The sweeps' counts follow along live from two `Portal.AdminEvents` topics.
  On `:sweeps`, `Portal.BulkRebuild` announces a sweep that starts or is
  cancelled, and `Portal.AdminEvents.SweepTelemetry` each sweep job attempt
  Oban records. On `:builders`, `Portal.Builders.Leases` announces each
  lease state change: a remote build's job completes once it has written its
  lease, so from then on `Portal.BulkRebuild.status/1` counts it by that
  lease alone. Both topics share one throttle window, so the table refetches
  at most once per window however the events mix, and a sweep of thousands
  of jobs costs two refreshes a second, not thousands.

  Each click and each bulk action re-runs the admin policy against a freshly
  loaded user, as the controller actions this replaces did on every request.

  Revoking a run, repairing file modes and the toolchain sweep stay plain
  forms posting to `PortalWeb.PageController`, which redirects back here.
  """
  use PortalWeb, :live_view

  import PortalWeb.AdminComponents
  import PortalWeb.Admin.LiveAuth

  alias Portal.BulkRebuild
  alias PortalWeb.AdminMessages

  @tables ["sweeps"]

  @impl true
  def mount(_params, session, socket) do
    if connected?(socket) do
      Portal.AdminEvents.subscribe(:sweeps)
      Portal.AdminEvents.subscribe(:builders)
    end

    user_id = session["user_id"]
    login_method = session["login_method"]
    started_at = session["session_started_at"]

    {:ok,
     socket
     |> assign(
       page_title: "Admin",
       page_description: "Administration.",
       user_id: user_id,
       login_method: login_method,
       session_started_at: started_at,
       bulk_targets: BulkRebuild.targets(),
       counts_version: 0,
       # Newest first, as `Portal.BulkRebuild.recent/1` listed them. Cinder
       # takes the query's sort as the table's default and drops it once a
       # header sort is chosen.
       sweeps_query: Ash.Query.sort(Portal.Catalog.BulkSweep, inserted_at: :desc, id: :desc),
       # Built once, here: it closes over the session the page was opened
       # with, so it can re-check the admin when the bulk bar calls it.
       bulk_cancel: as_admin_bulk(&BulkRebuild.bulk_cancel/2, user_id, login_method, started_at)
     )
     |> load_panels()}
  end

  # What the cards above and below the sweeps show. Read on mount and again
  # after the update check is queued, as the controller page read it on every
  # render.
  defp load_panels(socket) do
    assign(socket,
      update_check: Portal.Admin.update_check_status(),
      precompiled: %{
        key_loaded?: match?({:ok, _}, Portal.Precompiled.Keys.load()),
        batch: Portal.Precompiled.Batches.latest()
      },
      toolchains: toolchain_rows()
    )
  end

  # In configured order, which a map of counts would lose.
  defp toolchain_rows do
    counts = Portal.Catalog.toolchain_counts()

    %{
      builder_version: Portal.Toolchains.builder_version(),
      rows:
        for %{toolchain: toolchain} <- Portal.Toolchains.images() do
          Map.put(Map.fetch!(counts, toolchain), :toolchain, toolchain)
        end
    }
  end

  @impl true
  def handle_params(params, uri, socket) do
    {:noreply, Cinder.UrlSync.handle_params(sane_page(params), uri, socket)}
  end

  # No redirect after these, unlike the controller actions they replace: a
  # LiveView event is not re-sent when the page reloads, so a refresh cannot
  # start a second sweep of forced builds.
  @impl true
  def handle_event("bulk_rebuild", params, socket) do
    as_admin(socket, fn socket, user ->
      bulk_rebuild(socket, BulkRebuild.opts_from_params(params, user.username))
    end)
  end

  def handle_event("cancel_sweep", params, socket) do
    as_admin(socket, fn socket, _user ->
      case Ecto.UUID.cast(string_param(params, "id")) do
        {:ok, sweep_id} ->
          {:ok, n} = BulkRebuild.cancel(sweep_id)
          done(socket, :info, "Cancelled #{n} waiting jobs.")

        :error ->
          done(socket, :error, "That sweep id is not valid.")
      end
    end)
  end

  def handle_event("update_check", params, socket) do
    as_admin(socket, fn socket, _user ->
      dry_run = params["mode"] == "dry_run"

      case Portal.Admin.request_update_check(dry_run: dry_run) do
        {:ok, _job} ->
          {:noreply, socket |> put_flash(:info, update_check_message(dry_run)) |> load_panels()}

        {:error, reason} ->
          {:noreply, socket |> put_flash(:error, AdminMessages.error(reason)) |> load_panels()}
      end
    end)
  end

  defp bulk_rebuild(socket, opts) do
    if opts[:what] == :no_targets do
      done(socket, :error, "Pick at least one target, or choose all targets or argus only.")
    else
      case {opts[:dry_run], BulkRebuild.run(opts)} do
        {true, {:ok, %{selected: n}}} ->
          done(socket, :info, "Dry run: would rebuild #{n} packages.")

        {false, {:ok, %{selected: n}}} ->
          done(socket, :info, "Bulk rebuild queued: #{pluralize(n, "package")}.")

        {_, {:error, reason}} ->
          done(socket, :error, AdminMessages.error(reason))
      end
    end
  end

  # A lease change is throttled under `:sweeps` too, so a lease storm and a
  # job storm share one window and its single trailing
  # `{:admin_refresh, :sweeps}`.
  @impl true
  def handle_info({:admin_changed, topic}, socket) when topic in [:sweeps, :builders] do
    case Portal.AdminEvents.throttle(socket, :sweeps) do
      {:refresh, socket} -> {:noreply, refresh_sweeps(socket)}
      {:skip, socket} -> {:noreply, socket}
    end
  end

  def handle_info({:admin_refresh, :sweeps}, socket),
    do: {:noreply, refresh_sweeps(socket)}

  # Cinder sends the action's own `{:ok, result}` unwrapped, as `result`.
  # Cancelling cannot refuse a sweep, so this reads as the single cancel does.
  def handle_info({:bulk_done, %{result: %{ok: n}}}, socket),
    do: done(socket, :info, "Cancelled #{n} waiting jobs.")

  def handle_info({:bulk_failed, %{reason: {:refused, refusal}}}, socket),
    do: refuse(socket, refusal)

  def handle_info({:bulk_failed, %{reason: reason}}, socket),
    do: {:noreply, put_flash(socket, :error, AdminMessages.error(reason))}

  def handle_info({:table_state_change, _table_id, encoded_state}, socket),
    do: table_state_change(socket, encoded_state)

  defp update_check_message(true),
    do: "Dry run queued. It reports what it would rebuild and queues nothing."

  defp update_check_message(false), do: "Update check queued."

  defp pluralize(1, word), do: "1 #{word}"
  defp pluralize(count, word), do: "#{count} #{word}s"

  # Cinder renders its rows with a `:for`, and LiveView re-renders only the
  # rows whose record changed. `:counts` is loaded fresh on every refetch, so
  # a sweep whose jobs moved already renders as a different `BulkSweep`; the
  # counter is kept anyway; it costs nothing and guards against any case
  # where Ash returns an `==` struct despite changed job state underneath.
  defp refresh_sweeps(socket) do
    socket
    |> update(:counts_version, &(&1 + 1))
    |> Cinder.refresh_tables(@tables)
  end

  defp done(socket, kind, message) do
    {:noreply, socket |> put_flash(kind, message) |> refresh_sweeps()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.admin_layout
      flash={@flash}
      current_user={@current_user}
      section={:maintenance}
      title="Maintenance"
    >
      <:subtitle>
        Scheduled jobs. Every job is also visible on the <.link href={~p"/admin/oban"} class="link">Oban dashboard</.link>.
      </:subtitle>
      <section class="card border border-base-300 bg-base-100 shadow-sm">
        <div class="card-body">
          <div class="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
            <div>
              <h2 class="card-title">hex.pm update check</h2>
              <p class="mt-1 text-sm leading-6 text-base-content/70">
                Runs hourly, compares tracked packages against the hex.pm registry, and queues every eligible update. Pure-Elixir packages skip firmware builds after host checks.
              </p>
            </div>
            <span class={[
              "badge w-fit",
              if(@update_check.enabled?, do: "badge-success", else: "badge-error")
            ]}>
              {if @update_check.enabled?, do: "Scheduled", else: "Schedule off"}
            </span>
          </div>

          <%= if @update_check.last_run do %>
            <% meta = @update_check.last_run.meta %>
            <div class="mt-5 grid gap-3 sm:grid-cols-3">
              <PortalWeb.UI.stat_card label="On hex" value={to_string(meta["seen"])} />
              <PortalWeb.UI.stat_card label="Worth rebuilding" value={to_string(meta["moved"])} />
              <PortalWeb.UI.stat_card label="Queued" value={to_string(meta["enqueued"])} />
            </div>
            <p class="mt-3 text-sm leading-6 text-base-content/70">
              Last run {format_datetime(@update_check.last_run.completed_at)}
              <%= if meta["dry_run"] do %>
                , as a dry run -- nothing was queued
              <% end %>.
            </p>
          <% else %>
            <p class="mt-5 text-sm leading-6 text-base-content/70">
              No run has recorded any numbers yet.
            </p>
          <% end %>

          <.form
            for={%{}}
            id="update-check"
            phx-submit="update_check"
            class="mt-5 flex flex-wrap items-center gap-2"
          >
            <button
              type="submit"
              name="mode"
              value="run"
              class="btn btn-sm btn-primary"
              disabled={@update_check.pending?}
            >
              Run now
            </button>
            <button type="submit" name="mode" value="dry_run" class="btn btn-sm btn-ghost">
              Dry run
            </button>
            <span class="text-sm text-base-content/60">
              <%= if @update_check.pending? do %>
                A check is already queued.
              <% else %>
                Either runs even while the schedule is off. A dry run queues nothing.
              <% end %>
            </span>
          </.form>
        </div>
      </section>

      <section class="card mt-6 border border-base-300 bg-base-100 shadow-sm">
        <div class="card-body">
          <h2 class="card-title">Bulk rebuild</h2>
          <p class="mt-1 text-sm leading-6 text-base-content/70">
            Rebuilds packages that were built before, at the lowest priority. Use it after a worker
            or argus change. Systems a partial rebuild leaves out keep their previous result.
            Packages with a release newer than their last build are rebuilt in full.
          </p>

          <.form for={%{}} id="bulk-rebuild" phx-submit="bulk_rebuild" class="mt-5 space-y-4">
            <div class="grid gap-4 sm:grid-cols-3">
              <label class="flex flex-col gap-1 text-sm text-base-content/70">
                Limit
                <input
                  type="number"
                  name="limit"
                  value="100"
                  min="1"
                  max="20000"
                  class="input input-bordered input-sm"
                />
              </label>

              <label class="flex flex-col gap-1 text-sm text-base-content/70">
                Order
                <select name="order" class="select select-bordered select-sm">
                  <option value="stalest">Stalest first</option>
                  <option value="catalog">Catalog order</option>
                </select>
              </label>

              <label class="flex flex-col gap-1 text-sm text-base-content/70">
                Result
                <select name="status" class="select select-bordered select-sm">
                  <option value="">Any result</option>
                  <option value="pass">Passing</option>
                  <option value="fail">Failing</option>
                  <option value="error">Errored</option>
                </select>
              </label>
            </div>

            <fieldset class="space-y-2">
              <legend class="text-sm text-base-content/70">What to rebuild</legend>
              <label class="flex items-center gap-2 text-sm">
                <input type="radio" name="what" value="full" checked class="radio radio-sm" />
                All targets + argus
              </label>
              <label class="flex items-center gap-2 text-sm">
                <input type="radio" name="what" value="argus_only" class="radio radio-sm" />
                Argus only
              </label>
              <label class="flex items-center gap-2 text-sm">
                <input type="radio" name="what" value="targets" class="radio radio-sm" />
                Selected targets
              </label>
              <div class="ml-6 flex flex-wrap gap-3">
                <label :for={target <- @bulk_targets} class="flex items-center gap-1.5 text-sm">
                  <input
                    type="checkbox"
                    name="systems[]"
                    value={target}
                    class="checkbox checkbox-sm"
                  />
                  <span class="font-mono text-xs">{target}</span>
                </label>
              </div>
            </fieldset>

            <div class="flex flex-wrap items-center gap-2">
              <button type="submit" name="mode" value="dry_run" class="btn btn-sm btn-ghost">
                Dry run
              </button>
              <%!-- app.js rewrites the question from the form's current limit and
                   scope before phoenix_html asks it; this is the text without JS
                   changes, for the defaults. --%>
              <button
                type="submit"
                name="mode"
                value="run"
                class="btn btn-sm btn-primary"
                data-bulk-confirm
                data-confirm="Queue forced Docker builds for up to 100 packages (All targets + argus)?"
              >
                Start
              </button>
            </div>
          </.form>

          <div id="sweeps-table" class="mt-6">
            <Cinder.collection
              id="sweeps"
              query={@sweeps_query}
              query_opts={[load: [:counts]]}
              actor={@current_user}
              url_state={@url_state}
              selectable
              page_size={10}
              empty_message="No bulk rebuild has been started yet."
            >
              <:col :let={s} field="inserted_at" label="Started" sort>
                <span class="text-base-content/70">{format_datetime(s.inserted_at)}</span>
              </:col>
              <:col
                :let={s}
                field="what"
                label="What"
                filter={[type: :select, options: what_options()]}
              >
                {what_label(s)}
              </:col>
              <:col :let={s} label="Counts">
                <.sweep_counts sweep={s} version={@counts_version} />
              </:col>
              <:col :let={s} label="">
                <span :if={s.cancelled_at} class="text-base-content/50">Cancelled</span>
                <button
                  :if={!s.cancelled_at}
                  id={"cancel-sweep-#{s.id}"}
                  type="button"
                  phx-click="cancel_sweep"
                  phx-value-id={s.id}
                  data-confirm="Cancel this sweep's waiting jobs?"
                  class="btn btn-xs btn-ghost"
                >
                  Cancel
                </button>
              </:col>
              <:bulk_action
                action={@bulk_cancel}
                label="Cancel ({count})"
                variant={:danger}
                confirm="Cancel {count} sweeps?"
                on_success={:bulk_done}
                on_error={:bulk_failed}
              />
            </Cinder.collection>
          </div>
          <p class="mt-2 text-xs leading-5 text-base-content/60">
            Done, Failed and Cancelled count the finished jobs Oban still keeps, so they drop once
            its pruner removes old jobs; Remaining is exact. Cancelled also includes builds stopped
            by a policy violation and packages missing from hex.pm.
          </p>
        </div>
      </section>

      <section class="card mt-6 border border-base-300 bg-base-100 shadow-sm">
        <div class="card-body">
          <h2 class="card-title">Precompiled signing</h2>
          <p class="mt-1 text-sm leading-6 text-base-content/70">
            Batches are signed on a schedule and name every package with precompiled files.
            Revoking a run drops the files it built from the next batch, everywhere they were carried.
          </p>

          <dl class="mt-5 grid gap-3 sm:grid-cols-2">
            <div>
              <dt class="text-sm text-base-content/60">Signing key</dt>
              <dd class="text-sm">
                {if @precompiled.key_loaded?,
                  do: "loaded",
                  else: "no signing key (PRECOMPILED_SIGNING_KEY unset or unreadable)"}
              </dd>
            </div>
            <div>
              <dt class="text-sm text-base-content/60">Latest batch</dt>
              <dd class="text-sm">
                <%= if @precompiled.batch do %>
                  sequence {@precompiled.batch.sequence}, {@precompiled.batch.manifest_count} manifests,
                  issued {format_datetime(@precompiled.batch.issued_at)},
                  expires {format_datetime(@precompiled.batch.expires_at)}
                <% else %>
                  no batch yet
                <% end %>
              </dd>
            </div>
          </dl>

          <%!-- These three post to the controller, which redirects back here;
               `<.form>` with an `action` adds the CSRF token. --%>
          <.form
            for={%{}}
            id="revoke-run-form"
            action={~p"/admin/maintenance/revoke-run"}
            method="post"
            class="mt-5 flex flex-wrap items-center gap-2"
          >
            <label class="flex items-center gap-2 text-sm">
              Revoke run
              <input
                type="text"
                name="run_id"
                placeholder="run id"
                required
                class="input input-bordered input-sm"
              />
            </label>
            <button type="submit" class="btn btn-sm btn-error">Revoke</button>
          </.form>

          <.form
            for={%{}}
            id="repair-file-modes-form"
            action={~p"/admin/maintenance/repair-file-modes"}
            method="post"
            class="mt-3 flex flex-wrap items-center gap-2"
          >
            <button type="submit" id="repair-file-modes-button" class="btn btn-sm btn-outline">
              Repair published file modes
            </button>
            <span class="text-sm text-base-content/60">
              Copies each file's real mode from its run's footprint into the published manifests. One-off; safe to repeat.
            </span>
          </.form>
        </div>
      </section>

      <section id="toolchains" class="card mt-6 border border-base-300 bg-base-100 shadow-sm">
        <div class="card-body">
          <div class="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
            <div>
              <h2 class="card-title">Toolchains</h2>
              <p class="mt-1 text-sm leading-6 text-base-content/70">
                Pure-BEAM packages built per Elixir/OTP toolchain for <code>Mix.install</code>
                users, at builder version {@toolchains.builder_version}. The sweep runs daily and
                queues the backlog onto the single-slot toolchain queue.
              </p>
            </div>
            <.form
              for={%{}}
              id="toolchain-sweep-form"
              action={~p"/admin/maintenance/toolchain-sweep"}
              method="post"
            >
              <button type="submit" id="toolchain-sweep-button" class="btn btn-sm btn-primary">
                Run sweep now
              </button>
            </.form>
          </div>

          <div class="mt-5 overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>Toolchain</th>
                  <th class="text-right">Pass</th>
                  <th class="text-right">Skipped</th>
                  <th class="text-right">Fail</th>
                  <th class="text-right">Error</th>
                  <th class="text-right">Backlog</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={row <- @toolchains.rows}>
                  <td class="font-mono">{row.toolchain}</td>
                  <td
                    :for={key <- [:pass, :skipped, :fail, :error, :backlog]}
                    id={"toolchain-#{toolchain_dom_id(row.toolchain)}-#{key}"}
                    class="text-right tabular-nums"
                  >
                    {Map.fetch!(row, key)}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </section>
    </.admin_layout>
    """
  end

  @counts [
    selected: "Selected",
    remaining: "Remaining",
    intake: "Intake",
    queued: "Queued",
    building: "Building",
    done: "Done",
    failed: "Failed",
    cancelled: "Cancelled"
  ]

  attr :sweep, :any, required: true
  # Unused in the markup; see `refresh_sweeps/1`.
  attr :version, :integer, required: true

  # `:counts` is loaded once for the whole page by `Cinder.collection`'s
  # `query_opts` (`Portal.Catalog.Calculations.SweepCounts`), not called here
  # per row. Remaining is the one number that is exact, so it stands out, as
  # its column did in the controller page's table.
  defp sweep_counts(assigns) do
    assigns =
      assign(assigns,
        counts: @counts,
        values: Map.put(assigns.sweep.counts, :selected, assigns.sweep.selected)
      )

    ~H"""
    <dl class="grid grid-cols-4 gap-x-4 gap-y-1 text-sm">
      <div :for={{key, label} <- @counts} class="flex flex-col">
        <dt class={[
          "text-xs uppercase tracking-wide",
          if(key == :remaining, do: "text-base-content", else: "text-base-content/60")
        ]}>
          {label}
        </dt>
        <dd
          id={"sweep-#{@sweep.id}-#{key}"}
          class={["tabular-nums", key == :remaining && "font-semibold"]}
        >
          {Map.fetch!(@values, key)}
        </dd>
      </div>
    </dl>
    """
  end

  defp what_options,
    do: [{"All targets", "full"}, {"Argus only", "argus_only"}, {"Selected targets", "targets"}]

  defp what_label(%{what: "full"}), do: "all targets"
  defp what_label(%{what: "argus_only"}), do: "argus only"
  defp what_label(sweep), do: Enum.join(sweep.systems || [], ", ")
end
