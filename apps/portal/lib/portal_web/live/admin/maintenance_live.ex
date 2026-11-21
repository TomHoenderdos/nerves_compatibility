defmodule PortalWeb.Admin.MaintenanceLive do
  @moduledoc """
  Admin Maintenance tab: the hex.pm update check, bulk rebuilds with their
  sweeps in a Cinder table, precompiled signing, the toolchain backlog and
  how much of the most downloaded packages the toolchain builds cover
  (`Portal.Catalog.Coverage`) and the two coverage metrics over every
  package (`Portal.Catalog.CoverageMetrics`), as the last
  `Portal.Workers.CoverageRefresh` stored them: the page and its buttons ask Hex nothing, and the refresh button
  only queues that job.

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

  require Logger

  alias Portal.BulkRebuild
  alias Portal.Catalog.Coverage
  alias Portal.Catalog.CoverageMetrics
  alias Portal.Workers.CoverageRefresh
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
      toolchains: toolchain_settings(),
      # The stored report: computing it asks Hex about every ranked
      # package, which a page load must not (`Portal.Workers.CoverageRefresh`).
      coverage: Coverage.latest(),
      coverage_metrics: CoverageMetrics.latest(),
      build_cache_l2: Portal.BuildCache.L2.status()
    )
    |> load_toolchain_counts()
  end

  # The per-toolchain counts are slow on a large catalog: the backlog count
  # runs the sweep's candidate query once per toolchain (tens of seconds in
  # production). The page renders without them and fills them in once the
  # LiveView is connected, so neither the HTTP render nor the socket mount
  # waits for them.
  defp load_toolchain_counts(socket) do
    if connected?(socket) do
      start_async(socket, :toolchain_counts, &toolchain_count_rows/0)
    else
      socket
    end
  end

  # The cheap part of the Toolchains card: the settings and the configured
  # worlds. `rows` stays `nil` until `toolchain_count_rows/0` answers.
  defp toolchain_settings do
    %{
      builder_version: Portal.Toolchains.builder_version(),
      worlds_enabled: Portal.Settings.get().world_variants_enabled,
      firmware_world_enabled: Portal.Settings.get().firmware_world_enabled,
      host_native_enabled: Portal.Settings.get().host_native_enabled,
      deterministic_enabled: Portal.Settings.get().deterministic_builds_enabled,
      foreign_priv_enabled: Portal.Settings.get().foreign_priv_enabled,
      relocated_enabled: Portal.Settings.get().relocated_enabled,
      relocate_builds_enabled: Portal.Settings.get().relocate_builds_enabled,
      worlds: Portal.Toolchains.worlds(),
      world_top_packages: Portal.Toolchains.world_top_packages(),
      rows: nil
    }
  end

  # In configured order, which a map of counts would lose.
  defp toolchain_count_rows do
    counts = Portal.Catalog.toolchain_counts()
    worlds = Portal.Catalog.toolchain_world_counts()

    for %{toolchain: toolchain} <- Portal.Toolchains.images() do
      counts
      |> Map.fetch!(toolchain)
      |> Map.merge(%{toolchain: toolchain, world: Map.fetch!(worlds, toolchain)})
    end
  end

  @impl true
  def handle_async(:toolchain_counts, {:ok, rows}, socket) do
    {:noreply, update(socket, :toolchains, &Map.put(&1, :rows, rows))}
  end

  def handle_async(:toolchain_counts, {:exit, reason}, socket) do
    Logger.warning("admin maintenance: toolchain counts failed: #{inspect(reason, limit: 5)}")
    {:noreply, update(socket, :toolchains, &Map.put(&1, :rows, :error))}
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

  def handle_event("refresh_coverage", _params, socket) do
    as_admin(socket, fn socket, _user ->
      case CoverageRefresh.enqueue() do
        {:ok, _job} ->
          done(socket, :info, "Coverage refresh queued. Reload the page once it has run.")

        {:error, reason} ->
          done(socket, :error, AdminMessages.error(reason))
      end
    end)
  end

  # The button carries the state it offers to switch to, which is what the
  # admin saw: a second click on a stale page repeats the same intent rather
  # than flipping it back.
  def handle_event("toggle_world_variants", params, socket) do
    as_admin(socket, fn socket, user ->
      enabled = params["enabled"] == "true"

      case Portal.Admin.set_world_variants_enabled(enabled, user) do
        {:ok, _setting} ->
          {:noreply,
           socket
           |> put_flash(:info, "World builds turned #{if enabled, do: "on", else: "off"}.")
           |> load_panels()}

        {:error, reason} ->
          {:noreply, socket |> put_flash(:error, AdminMessages.error(reason)) |> load_panels()}
      end
    end)
  end

  def handle_event("toggle_firmware_world", params, socket) do
    as_admin(socket, fn socket, user ->
      enabled = params["enabled"] == "true"

      case Portal.Admin.set_firmware_world_enabled(enabled, user) do
        {:ok, _setting} ->
          {:noreply,
           socket
           |> put_flash(
             :info,
             "Firmware world builds turned #{if enabled, do: "on", else: "off"}."
           )
           |> load_panels()}

        {:error, reason} ->
          {:noreply, socket |> put_flash(:error, AdminMessages.error(reason)) |> load_panels()}
      end
    end)
  end

  def handle_event("toggle_host_native", params, socket) do
    as_admin(socket, fn socket, user ->
      enabled = params["enabled"] == "true"

      case Portal.Admin.set_host_native_enabled(enabled, user) do
        {:ok, _setting} ->
          {:noreply,
           socket
           |> put_flash(:info, "Host-native builds turned #{if enabled, do: "on", else: "off"}.")
           |> load_panels()}

        {:error, reason} ->
          {:noreply, socket |> put_flash(:error, AdminMessages.error(reason)) |> load_panels()}
      end
    end)
  end

  def handle_event("toggle_deterministic", params, socket) do
    as_admin(socket, fn socket, user ->
      enabled = params["enabled"] == "true"

      case Portal.Admin.set_deterministic_builds_enabled(enabled, user) do
        {:ok, _setting} ->
          {:noreply,
           socket
           |> put_flash(
             :info,
             "Deterministic builds turned #{if enabled, do: "on", else: "off"}."
           )
           |> load_panels()}

        {:error, reason} ->
          {:noreply, socket |> put_flash(:error, AdminMessages.error(reason)) |> load_panels()}
      end
    end)
  end

  def handle_event("toggle_relocate_builds", params, socket) do
    as_admin(socket, fn socket, user ->
      enabled = params["enabled"] == "true"

      case Portal.Admin.set_relocate_builds_enabled(enabled, user) do
        {:ok, _setting} ->
          {:noreply,
           socket
           |> put_flash(
             :info,
             "Relocation in builds turned #{if enabled, do: "on", else: "off"}."
           )
           |> load_panels()}

        {:error, reason} ->
          {:noreply, socket |> put_flash(:error, AdminMessages.error(reason)) |> load_panels()}
      end
    end)
  end

  def handle_event("toggle_relocated", params, socket) do
    as_admin(socket, fn socket, user ->
      enabled = params["enabled"] == "true"

      case Portal.Admin.set_relocated_enabled(enabled, user) do
        {:ok, _setting} ->
          {:noreply,
           socket
           |> put_flash(:info, "Relocated builds turned #{if enabled, do: "on", else: "off"}.")
           |> load_panels()}

        {:error, reason} ->
          {:noreply, socket |> put_flash(:error, AdminMessages.error(reason)) |> load_panels()}
      end
    end)
  end

  def handle_event("toggle_foreign_priv", params, socket) do
    as_admin(socket, fn socket, user ->
      enabled = params["enabled"] == "true"

      case Portal.Admin.set_foreign_priv_enabled(enabled, user) do
        {:ok, _setting} ->
          {:noreply,
           socket
           |> put_flash(:info, "Foreign priv builds turned #{if enabled, do: "on", else: "off"}.")
           |> load_panels()}

        {:error, reason} ->
          {:noreply, socket |> put_flash(:error, AdminMessages.error(reason)) |> load_panels()}
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

  defp format_percent(percent), do: :erlang.float_to_binary(percent, decimals: 1) <> "%"

  defp gap_reason(:no_host_build), do: "No build of any version"
  defp gap_reason(:no_build_for_version), do: "No build of this version"
  defp gap_reason(:failed), do: "Build failed"
  defp gap_reason(:no_optional_deps_build), do: "Built without optional deps"

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

  defp toolchain_rows_list(%{rows: rows}) when is_list(rows), do: rows
  defp toolchain_rows_list(_toolchains), do: []

  defp world_dom_key(key), do: key |> Atom.to_string() |> String.replace("_", "-")

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

          <.form
            for={%{}}
            id="system-abi-backfill-form"
            action={~p"/admin/maintenance/system-abi-backfill"}
            method="post"
            class="mt-3 flex flex-wrap items-center gap-2"
          >
            <button type="submit" id="system-abi-backfill-button" class="btn btn-sm btn-outline">
              Backfill system ABI
            </button>
            <span class="text-sm text-base-content/60">
              Reads the ELF facts of older published target builds, fills their toolchain and OTP, and queues library reads for their system releases. Safe to repeat.
            </span>
          </.form>
        </div>
      </section>

      <section id="build-cache-l2" class="card mt-6 border border-base-300 bg-base-100 shadow-sm">
        <div class="card-body">
          <div class="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
            <div>
              <h2 class="card-title">Build cache L2</h2>
              <p class="mt-1 text-sm leading-6 text-base-content/70">
                The shared S3 layer behind the local dependency build cache: read before every
                build, written after every promotion. Counters are this node's ({@build_cache_l2.node})
                since it booted.
              </p>
            </div>
            <span class={[
              "badge w-fit",
              case @build_cache_l2.state do
                :on -> "badge-success"
                :incomplete -> "badge-error"
                :off -> "badge-ghost"
              end
            ]}>
              {case @build_cache_l2.state do
                :on -> "On"
                :incomplete -> "Incomplete config"
                :off -> "Off"
              end}
            </span>
          </div>
          <%= if @build_cache_l2.state == :on do %>
            <p class="mt-3 text-sm leading-6 text-base-content/70">
              {@build_cache_l2.endpoint}/{@build_cache_l2.bucket}
              <%= if @build_cache_l2.read_only? do %>
                , read-only
              <% end %>.
              Last upload {if @build_cache_l2.last_upload,
                do: format_datetime(@build_cache_l2.last_upload),
                else: "never"},
              last download {if @build_cache_l2.last_download,
                do: format_datetime(@build_cache_l2.last_download),
                else: "never"}.
              <%= if @build_cache_l2.max_bytes do %>
                Above 90% of {div(@build_cache_l2.max_bytes, 1_000_000_000)} GB the oldest objects
                are deleted, down to 75%, at most hourly.
              <% end %>
            </p>
            <div class="mt-5 grid gap-3 sm:grid-cols-3 lg:grid-cols-5">
              <PortalWeb.UI.stat_card
                label="Uploads"
                value={"#{@build_cache_l2.counters.uploads} (#{@build_cache_l2.counters.upload_failures} failed)"}
              />
              <PortalWeb.UI.stat_card
                label="Downloads"
                value={"#{@build_cache_l2.counters.downloads} (#{@build_cache_l2.counters.download_failures} failed, #{@build_cache_l2.counters.refused} refused)"}
              />
              <PortalWeb.UI.stat_card
                label="Bytes up"
                value={to_string(@build_cache_l2.counters.bytes_up)}
              />
              <PortalWeb.UI.stat_card
                label="Bytes down"
                value={to_string(@build_cache_l2.counters.bytes_down)}
              />
              <PortalWeb.UI.stat_card
                label="Evictions"
                value={"#{@build_cache_l2.counters.evictions} (#{@build_cache_l2.counters.evicted_bytes} bytes)"}
              />
            </div>
          <% end %>
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
                <tr :if={@toolchains.rows == nil} id="toolchain-counts-loading">
                  <td colspan="6" class="text-base-content/60">Loading counts…</td>
                </tr>
                <tr :if={@toolchains.rows == :error} id="toolchain-counts-error">
                  <td colspan="6" class="text-error">The counts could not be loaded.</td>
                </tr>
                <tr :for={row <- toolchain_rows_list(@toolchains)}>
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

          <div
            id="world-builds"
            class="mt-6 flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between"
          >
            <div>
              <h3 class="font-semibold">World builds</h3>
              <p class="mt-1 text-sm leading-6 text-base-content/70">
                <span id="world-variants-state">
                  World builds are {if @toolchains.worlds_enabled, do: "on", else: "off"}.
                </span>
                Worlds {Enum.join(@toolchains.worlds, ", ")}, for the {@toolchains.world_top_packages ||
                  "all"} most downloaded packages. Served only under <code>builds_closure</code>.
                Turn on only once every node, toolchain builders included, runs this release.
                Candidates count what the backlog wants, on or off.
              </p>
            </div>
            <button
              type="button"
              id="world-variants-toggle"
              phx-click="toggle_world_variants"
              phx-value-enabled={to_string(not @toolchains.worlds_enabled)}
              class={[
                "btn btn-sm",
                if(@toolchains.worlds_enabled, do: "btn-ghost", else: "btn-primary")
              ]}
            >
              {if @toolchains.worlds_enabled,
                do: "Turn world builds off",
                else: "Turn world builds on"}
            </button>
          </div>

          <div
            id="firmware-world-builds"
            class="mt-6 flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between"
          >
            <div>
              <h3 class="font-semibold">Firmware world builds</h3>
              <p class="mt-1 text-sm leading-6 text-base-content/70">
                <span id="firmware-world-state">
                  Firmware world builds are {if @toolchains.firmware_world_enabled,
                    do: "on",
                    else: "off"}.
                </span>
                Each firmware build also compiles the package per passing target with the
                optional deps a default <code>mix nerves.new</code>
                app has (<code>world_nerves</code>), served only under <code>builds_closure</code>.
                Turn on only once every firmware builder runs a worker image that builds it.
              </p>
            </div>
            <button
              type="button"
              id="firmware-world-toggle"
              phx-click="toggle_firmware_world"
              phx-value-enabled={to_string(not @toolchains.firmware_world_enabled)}
              class={[
                "btn btn-sm",
                if(@toolchains.firmware_world_enabled, do: "btn-ghost", else: "btn-primary")
              ]}
            >
              {if @toolchains.firmware_world_enabled,
                do: "Turn firmware world builds off",
                else: "Turn firmware world builds on"}
            </button>
          </div>

          <div
            id="host-native-builds"
            class="mt-6 flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between"
          >
            <div>
              <h3 class="font-semibold">Host-native builds</h3>
              <p class="mt-1 text-sm leading-6 text-base-content/70">
                <span id="host-native-state">
                  Host-native builds are {if @toolchains.host_native_enabled, do: "on", else: "off"}.
                </span>
                NIF packages built for a glibc Linux triple on the toolchain images, queued,
                listed under <code>builds_host_native</code>
                and their files served only while
                this is on. Clients use them only with <code>host_native: true</code>.
              </p>
            </div>
            <button
              type="button"
              id="host-native-toggle"
              phx-click="toggle_host_native"
              phx-value-enabled={to_string(not @toolchains.host_native_enabled)}
              class={[
                "btn btn-sm",
                if(@toolchains.host_native_enabled, do: "btn-ghost", else: "btn-primary")
              ]}
            >
              {if @toolchains.host_native_enabled,
                do: "Turn host-native builds off",
                else: "Turn host-native builds on"}
            </button>
          </div>

          <div
            id="deterministic-builds"
            class="mt-6 flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between"
          >
            <div>
              <h3 class="font-semibold">Deterministic builds</h3>
              <p class="mt-1 text-sm leading-6 text-base-content/70">
                <span id="deterministic-state">
                  Deterministic builds are {if @toolchains.deterministic_enabled,
                    do: "on",
                    else: "off"}.
                </span>
                Each toolchain build, and each passing firmware target's build, is compiled again with
                <code>ERL_COMPILER_OPTIONS=deterministic</code>
                and judged, and these siblings are listed under a version's <code>deterministic</code>
                key and their files served, only while this is on. Only clients whose project sets
                exactly that option use them.
              </p>
            </div>
            <button
              type="button"
              id="deterministic-toggle"
              phx-click="toggle_deterministic"
              phx-value-enabled={to_string(not @toolchains.deterministic_enabled)}
              class={[
                "btn btn-sm",
                if(@toolchains.deterministic_enabled, do: "btn-ghost", else: "btn-primary")
              ]}
            >
              {if @toolchains.deterministic_enabled,
                do: "Turn deterministic builds off",
                else: "Turn deterministic builds on"}
            </button>
          </div>

          <div
            id="foreign-priv-builds"
            class="mt-6 flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between"
          >
            <div>
              <h3 class="font-semibold">Foreign priv builds</h3>
              <p class="mt-1 text-sm leading-6 text-base-content/70">
                <span id="foreign-priv-state">
                  Foreign priv builds are {if @toolchains.foreign_priv_enabled,
                    do: "on",
                    else: "off"}.
                </span>
                Writers that pack Kino.JS assets into kino's priv, and kino's own builds, for
                clients 0.8.0 and later. Off withdraws every one at the next batch, and no build
                job asks for the judge's foreign priv rule.
              </p>
            </div>
            <button
              type="button"
              id="foreign-priv-toggle"
              phx-click="toggle_foreign_priv"
              phx-value-enabled={to_string(not @toolchains.foreign_priv_enabled)}
              class={[
                "btn btn-sm",
                if(@toolchains.foreign_priv_enabled, do: "btn-ghost", else: "btn-primary")
              ]}
            >
              {if @toolchains.foreign_priv_enabled,
                do: "Turn foreign priv builds off",
                else: "Turn foreign priv builds on"}
            </button>
          </div>

          <div
            id="relocate-builds"
            class="mt-6 flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between"
          >
            <div>
              <h3 class="font-semibold">Relocation in builds</h3>
              <p class="mt-1 text-sm leading-6 text-base-content/70">
                <span id="relocate-builds-state">
                  Relocation in builds is {if @toolchains.relocate_builds_enabled,
                    do: "on",
                    else: "off"}.
                </span>
                Toolchain builds whose beams hold their build's paths are built again at two more
                roots and, when every root proves, stored as relocated builds. It serves nothing by
                itself; relocated builds below decides that.
              </p>
            </div>
            <button
              type="button"
              id="relocate-builds-toggle"
              phx-click="toggle_relocate_builds"
              phx-value-enabled={to_string(not @toolchains.relocate_builds_enabled)}
              class={[
                "btn btn-sm",
                if(@toolchains.relocate_builds_enabled, do: "btn-ghost", else: "btn-primary")
              ]}
            >
              {if @toolchains.relocate_builds_enabled,
                do: "Turn relocation in builds off",
                else: "Turn relocation in builds on"}
            </button>
          </div>

          <div
            id="relocated-builds"
            class="mt-6 flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between"
          >
            <div>
              <h3 class="font-semibold">Relocated builds</h3>
              <p class="mt-1 text-sm leading-6 text-base-content/70">
                <span id="relocated-state">
                  Relocated builds are {if @toolchains.relocated_enabled, do: "on", else: "off"}.
                </span>
                Builds whose beams hold their build's deps or build path, rewritten to the
                project's own paths at install by clients 0.9.0 and later. Off withdraws every
                one at the next batch.
              </p>
            </div>
            <button
              type="button"
              id="relocated-toggle"
              phx-click="toggle_relocated"
              phx-value-enabled={to_string(not @toolchains.relocated_enabled)}
              class={[
                "btn btn-sm",
                if(@toolchains.relocated_enabled, do: "btn-ghost", else: "btn-primary")
              ]}
            >
              {if @toolchains.relocated_enabled,
                do: "Turn relocated builds off",
                else: "Turn relocated builds on"}
            </button>
          </div>

          <div class="mt-3 overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>Toolchain</th>
                  <th class="text-right">Pass</th>
                  <th class="text-right">Skipped</th>
                  <th class="text-right">Same closure</th>
                  <th class="text-right">Fail</th>
                  <th class="text-right">Error</th>
                  <th class="text-right">Candidates</th>
                </tr>
              </thead>
              <tbody>
                <tr :if={@toolchains.rows == nil} id="toolchain-world-counts-loading">
                  <td colspan="7" class="text-base-content/60">Loading counts…</td>
                </tr>
                <tr :for={row <- toolchain_rows_list(@toolchains)}>
                  <td class="font-mono">{row.toolchain}</td>
                  <td
                    :for={key <- [:pass, :skipped, :same_closure, :fail, :error, :candidates]}
                    id={"toolchain-#{toolchain_dom_id(row.toolchain)}-world-#{world_dom_key(key)}"}
                    class="text-right tabular-nums"
                  >
                    {Map.fetch!(row.world, key)}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </section>

      <section id="coverage" class="card mt-6 border border-base-300 bg-base-100 shadow-sm">
        <div class="card-body">
          <div class="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
            <div>
              <h2 class="card-title">Precompiled coverage</h2>
              <p class="mt-1 text-sm leading-6 text-base-content/70">
                Of the most downloaded packages on hex.pm, how many have a served build of their
                latest stable version per toolchain, and how many of those builds carry the
                package's optional dependencies. Recomputed hourly.
              </p>
            </div>
            <button
              type="button"
              id="coverage-refresh"
              phx-click="refresh_coverage"
              class="btn btn-sm btn-primary"
            >
              Refresh now
            </button>
          </div>

          <div id="coverage-metrics" class="mt-5">
            <h3 class="text-sm font-semibold">All packages</h3>
            <p class="mt-1 text-sm leading-6 text-base-content/70">
              Every package at the newest stable release on Hex: the share of recent downloads
              served, and the share of the packages that compile. Nerves tooling and packages
              with nothing to compile are left out. A build whose closure is withheld counts as
              served; a compile failure is a failed toolchain compile (not one a signal killed),
              or, with no toolchain build, a failed host compile in the firmware project.
              Gleam packages leave the second share too: no Elixir before 1.22 compiles them.
            </p>
            <p
              :if={@coverage_metrics == nil}
              id="coverage-metrics-none"
              class="mt-3 text-sm text-base-content/70"
            >
              No metrics yet. The hourly refresh computes them, or queue it now.
            </p>
            <p
              :if={@coverage_metrics}
              id="coverage-metrics-computed-at"
              class="mt-3 text-sm text-base-content/70"
            >
              Computed
              <time datetime={DateTime.to_iso8601(@coverage_metrics.computed_at)}>
                {Calendar.strftime(@coverage_metrics.computed_at, "%Y-%m-%d %H:%M UTC")}
              </time>
            </p>
            <div :if={@coverage_metrics} class="mt-3 overflow-x-auto">
              <table class="table table-sm">
                <thead>
                  <tr>
                    <th>Toolchain</th>
                    <th class="text-right">Packages</th>
                    <th class="text-right">Served</th>
                    <th class="text-right">Download-weighted</th>
                    <th class="text-right">Of packages that compile</th>
                    <th class="text-right">Compile failures</th>
                    <th class="text-right">Nothing to compile</th>
                    <th class="text-right">Gleam</th>
                  </tr>
                </thead>
                <tbody>
                  <tr
                    :for={row <- @coverage_metrics.metrics.toolchains}
                    data-toolchain={row.toolchain}
                  >
                    <td class="font-mono">{row.toolchain}</td>
                    <td class="text-right tabular-nums">{row.packages}</td>
                    <td class="text-right tabular-nums">{row.served}</td>
                    <td data-column="download_percent" class="text-right tabular-nums">
                      {format_percent(row.download_percent)}
                    </td>
                    <td data-column="compile_percent" class="text-right tabular-nums">
                      {format_percent(row.compile_percent)}
                    </td>
                    <td class="text-right tabular-nums">{row.compile_failures}</td>
                    <td class="text-right tabular-nums">{row.nothing_to_compile}</td>
                    <td data-column="gleam" class="text-right tabular-nums">{row.gleam}</td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>

          <h3 class="mt-5 text-sm font-semibold">Most downloaded packages</h3>

          <p :if={@coverage == nil} id="coverage-none" class="mt-5 text-sm text-base-content/70">
            No coverage report yet. The hourly refresh computes one, or queue it now.
          </p>

          <p :if={@coverage} id="coverage-computed-at" class="mt-3 text-sm text-base-content/70">
            Top {@coverage.report.top_n} packages, computed
            <time datetime={DateTime.to_iso8601(@coverage.computed_at)}>
              {Calendar.strftime(@coverage.computed_at, "%Y-%m-%d %H:%M UTC")}
            </time>
          </p>

          <div :if={@coverage} class="mt-5 overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>Toolchain</th>
                  <th class="text-right">Ranked</th>
                  <th class="text-right">Covered</th>
                  <th class="text-right">With optional deps</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={row <- @coverage.report.toolchains} data-toolchain={row.toolchain}>
                  <td class="font-mono">{row.toolchain}</td>
                  <td class="text-right tabular-nums">{row.total}</td>
                  <td data-column="covered" class="text-right tabular-nums">
                    {row.covered} ({format_percent(row.percent)})
                  </td>
                  <td data-column="covered_with_optional" class="text-right tabular-nums">
                    {row.covered_with_optional} ({format_percent(row.percent_with_optional)})
                  </td>
                </tr>
              </tbody>
            </table>
          </div>

          <details
            :for={row <- if(@coverage, do: @coverage.report.toolchains, else: [])}
            :if={row.gaps != []}
            class="mt-4"
          >
            <summary class="cursor-pointer text-sm font-medium">
              <span class="font-mono">{row.toolchain}</span>: {pluralize(length(row.gaps), "gap")}
            </summary>
            <div class="mt-2 overflow-x-auto">
              <table class="table table-sm">
                <thead>
                  <tr>
                    <th>Package</th>
                    <th>Version</th>
                    <th class="text-right">Recent downloads</th>
                    <th>Reason</th>
                  </tr>
                </thead>
                <tbody>
                  <tr
                    :for={gap <- row.gaps}
                    data-gap={gap.package}
                    data-toolchain={row.toolchain}
                    data-reason={gap.reason}
                  >
                    <td class="font-mono">{gap.package}</td>
                    <td class="font-mono">{gap.version || "-"}</td>
                    <td class="text-right tabular-nums">{gap.downloads}</td>
                    <td>{gap_reason(gap.reason)}</td>
                  </tr>
                </tbody>
              </table>
            </div>
          </details>
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
