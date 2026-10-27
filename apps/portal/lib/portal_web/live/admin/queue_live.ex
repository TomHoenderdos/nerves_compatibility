defmodule PortalWeb.Admin.QueueLive do
  @moduledoc """
  Admin Queue tab: queue a package by hand, review anonymous submissions and
  reorder the build queue, each list a Cinder table with bulk actions.

  The page follows the queue live: `Portal.ScanRequests` announces every new
  request and status change on `Portal.AdminEvents`' `:queue` topic, and both
  tables refetch through their own queries, at most once per throttle
  window, so a bulk rebuild that touches thousands of rows costs two
  refreshes, not thousands.

  Each click and each bulk action re-runs the admin policy against a freshly
  loaded user, as the controller actions this replaces did on every request:
  an admin demoted or stripped of their passkey while the page is open is
  refused on the next click, not when the socket happens to reconnect.

  A bulk action's per-row work (`Portal.Admin.bulk_approve/2` and friends,
  each a hex.pm lookup per selected row) runs under `Portal.TaskSupervisor`,
  off this process, so a slow or down hex.pm freezes neither this admin's
  tab nor anyone else's: `as_admin_bulk/3` re-checks the admin, starts the
  task and returns at once, which Cinder reports through `on_success` as a
  "working" flash; the task reports the finished summary itself, straight to
  this process, once it is done.
  """
  use PortalWeb, :live_view

  import PortalWeb.AdminComponents
  import PortalWeb.PageHTML, only: [verification_label: 1, request_status_label: 1]

  require Ash.Query

  alias Portal.ScanRequests.ScanRequest
  alias PortalWeb.AdminMessages
  alias PortalWeb.Plugs.RequireAdmin

  @tables ["approvals", "queue"]

  # What the rows show, and no more: `error_log` alone can be 16 KB a row.
  @row_fields [:id, :package_name, :source, :status, :subject, :inserted_at]

  @impl true
  def mount(_params, session, socket) do
    if connected?(socket), do: Portal.AdminEvents.subscribe(:queue)

    user_id = session["user_id"]
    login_method = session["login_method"]

    # Oldest first, as the controller page listed both. Cinder takes the
    # query's sort as the table's default and drops it once a header sort is
    # chosen.
    oldest_first =
      ScanRequest
      |> Ash.Query.select(@row_fields)
      |> Ash.Query.sort(inserted_at: :asc, id: :asc)

    {:ok,
     assign(socket,
       page_title: "Admin",
       page_description: "Administration.",
       user_id: user_id,
       login_method: login_method,
       queue_form: to_form(%{"package_name" => "", "force" => "false"}),
       approvals_query:
         Ash.Query.filter(oldest_first, source == :anonymous_manual and status == :pending),
       queue_query: Ash.Query.filter(oldest_first, status in [:accepted, :queued]),
       # Built once, here: each closes over the session the page was opened
       # with, so it can re-check the admin when the bulk bar calls it.
       bulk: %{
         approve: as_admin_bulk(&Portal.Admin.bulk_approve/2, user_id, login_method),
         reject: as_admin_bulk(&Portal.Admin.bulk_reject/2, user_id, login_method),
         move_up: as_admin_bulk(&Portal.Admin.bulk_move_up/2, user_id, login_method),
         move_down: as_admin_bulk(&Portal.Admin.bulk_move_down/2, user_id, login_method)
       }
     )}
  end

  @impl true
  def handle_params(params, uri, socket) do
    {:noreply, Cinder.UrlSync.handle_params(sane_page(params), uri, socket)}
  end

  # Cinder turns `page` into an offset unchecked, and one past Postgres's
  # bigint fails the query and logs an error instead of showing anything.
  # The controller page fell back to a valid page; here an absurd one is
  # dropped, which shows the first.
  defp sane_page(%{"page" => page} = params) when is_binary(page) do
    case Integer.parse(page) do
      {n, ""} when n in 1..1_000_000 -> params
      _ -> Map.delete(params, "page")
    end
  end

  defp sane_page(%{"page" => _not_a_string} = params), do: Map.delete(params, "page")

  defp sane_page(params), do: params

  @impl true
  def handle_event("approve", params, socket) do
    as_admin(socket, fn socket, user ->
      case Portal.ScanRequests.approve_anonymous_request(string_param(params, "id"), user) do
        {:ok, request} ->
          done(socket, :info, "Approved anonymous request for #{request.package_name}.")

        {:error, reason} ->
          done(socket, :error, AdminMessages.error(reason))
      end
    end)
  end

  def handle_event("reject", params, socket) do
    as_admin(socket, fn socket, user ->
      case Portal.ScanRequests.reject_anonymous_request(string_param(params, "id"), user) do
        {:ok, request} ->
          done(socket, :info, "Rejected anonymous request for #{request.package_name}.")

        {:error, reason} ->
          done(socket, :error, AdminMessages.error(reason))
      end
    end)
  end

  def handle_event("reprioritise", params, socket) do
    as_admin(socket, fn socket, _user ->
      direction = if params["direction"] == "down", do: :down, else: :up

      case Portal.Admin.reprioritise(string_param(params, "id"), direction) do
        {:ok, priority} ->
          done(socket, :info, "Moved to priority #{priority}. Lower runs sooner.")

        {:error, reason} ->
          done(socket, :error, AdminMessages.error(reason))
      end
    end)
  end

  def handle_event("queue_package", params, socket) do
    as_admin(socket, fn socket, user ->
      force = params["force"] in ["true", "on", "1"]

      case Portal.Admin.queue_package(string_param(params, "package_name"), user, force: force) do
        {:ok, request} -> done(socket, :info, queued_message(request, force))
        {:error, reason} -> done(socket, :error, AdminMessages.error(reason))
      end
    end)
  end

  @impl true
  def handle_info({:admin_changed, :queue}, socket) do
    case Portal.AdminEvents.throttle(socket, :queue) do
      {:refresh, socket} -> {:noreply, Cinder.refresh_tables(socket, @tables)}
      {:skip, socket} -> {:noreply, socket}
    end
  end

  def handle_info({:admin_refresh, :queue}, socket),
    do: {:noreply, Cinder.refresh_tables(socket, @tables)}

  # Cinder's `on_success` fires the instant `as_admin_bulk/3` starts the
  # task, not when the task finishes -- see its moduledoc. `count` is what
  # Cinder itself counted off the selection, before the function ran.
  def handle_info({:bulk_done, %{count: count, result: :working}}, socket),
    do: {:noreply, put_flash(socket, :info, "Working on #{count} requests…")}

  # The real summary, sent straight to this process by the task once it
  # finishes -- same texts a synchronous bulk action gave before the work
  # moved off this process (see `bulk_message/2`).
  def handle_info({:bulk_async_result, {:ok, %{ok: ok, failed: failed}}}, socket) do
    {kind, message} = bulk_message(ok, failed)
    {:noreply, socket |> put_flash(kind, message) |> Cinder.refresh_tables(@tables)}
  end

  def handle_info({:bulk_async_result, {:error, reason}}, socket),
    do: {:noreply, put_flash(socket, :error, AdminMessages.error(reason))}

  def handle_info({:bulk_failed, %{reason: {:refused, refusal}}}, socket),
    do: refuse(socket, refusal)

  def handle_info({:bulk_failed, %{reason: reason}}, socket),
    do: {:noreply, put_flash(socket, :error, AdminMessages.error(reason))}

  # What `use Cinder.UrlSync` would inject, written out so it can sit with
  # the other `handle_info/2` clauses. Only the queue table syncs its state to
  # the URL (see the template), so only it sends this.
  def handle_info({:table_state_change, _table_id, encoded_state}, socket) do
    current_uri = get_in(socket.assigns, [:url_state, :uri])
    {:noreply, Cinder.UrlSync.update_url(socket, encoded_state, current_uri)}
  end

  defp bulk_message(ok, []), do: {:info, "#{ok} done."}

  defp bulk_message(ok, failed) do
    reasons =
      failed
      |> Enum.map(fn {_id, reason} -> AdminMessages.error(reason) end)
      |> Enum.uniq()
      |> Enum.join(" ")

    {:error, "#{ok} done, #{length(failed)} refused: #{reasons}"}
  end

  defp queued_message(request, true), do: "Queued a forced rebuild of #{request.package_name}."
  defp queued_message(request, false), do: "Queued #{request.package_name}."

  defp as_admin(socket, fun) do
    %{user_id: user_id, login_method: login_method} = socket.assigns

    case RequireAdmin.check(load_user(user_id), login_method) do
      {:ok, user} -> fun.(assign(socket, :current_user, user), user)
      {:error, refusal} -> refuse(socket, refusal)
    end
  end

  # Cinder calls a bulk action as `fun.(query, opts)`, with the actor it was
  # rendered with. That actor is a snapshot from the mount, so the admin is
  # re-checked here, synchronously, before anything else happens: a refusal
  # comes back as `{:error, {:refused, refusal}}` and Cinder hands it to
  # `{:bulk_failed, _}`, which redirects the way a click would, having
  # started no work and changed nothing.
  #
  # Once the actor checks out, the freshly loaded user goes in its place and
  # `bulk_fun` -- `Portal.Admin.bulk_approve/2` and friends, each a per-row
  # hex.pm lookup -- runs under `Portal.TaskSupervisor` instead of inline
  # here: this function returns at once, so a slow or down hex.pm never
  # blocks the socket that is about to render the "working" flash. The task
  # reports its result straight to this process; `handle_info/2` above turns
  # both messages into the flash the admin sees.
  defp as_admin_bulk(bulk_fun, user_id, login_method) do
    fn query, opts ->
      case RequireAdmin.check(load_user(user_id), login_method) do
        {:ok, user} -> start_bulk_task(bulk_fun, query, Keyword.put(opts, :actor, user))
        {:error, refusal} -> {:error, {:refused, refusal}}
      end
    end
  end

  defp start_bulk_task(bulk_fun, query, opts) do
    live_view = self()

    {:ok, _pid} =
      Task.Supervisor.start_child(Portal.TaskSupervisor, fn ->
        send(live_view, {:bulk_async_result, run_bulk(bulk_fun, query, opts)})
      end)

    {:ok, :working}
  end

  # `bulk_fun` already rescues per row (`Portal.Admin.each_request/3`), but a
  # crash above that loop -- the read of the query itself, say -- must still
  # reach the page as a message rather than leave its "working" flash
  # standing forever with the task simply gone.
  defp run_bulk(bulk_fun, query, opts) do
    bulk_fun.(query, opts)
  rescue
    e -> {:error, Exception.message(e)}
  end

  # A click carries what the button put in it, but a forged one may carry
  # anything; a missing or non-string value is refused by the context
  # function as blank or not found, not by crashing the page.
  defp string_param(params, key) do
    case params[key] do
      value when is_binary(value) -> value
      _other -> ""
    end
  end

  defp load_user(user_id) do
    case Portal.Accounts.get_user(user_id) do
      {:ok, user} -> user
      _ -> nil
    end
  end

  defp refuse(socket, %{to: to, flash: flash}) do
    {:noreply, socket |> put_flash(:error, flash) |> redirect(to: to)}
  end

  defp done(socket, kind, message) do
    {:noreply, socket |> put_flash(kind, message) |> Cinder.refresh_tables(@tables)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.admin_layout flash={@flash} current_user={@current_user} section={:queue} title="Queue">
      <:subtitle>Queue a scan, review anonymous submissions and reorder accepted requests.</:subtitle>

      <section class="card border border-base-300 bg-base-100 shadow-sm">
        <div class="card-body">
          <div class="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
            <div>
              <h2 class="card-title">Queue a scan</h2>
              <p class="mt-1 text-sm leading-6 text-base-content/70">
                Goes straight into the queue at the highest priority. No approval step.
              </p>
            </div>
            <span class="badge badge-outline w-fit">Admin</span>
          </div>

          <.form
            for={@queue_form}
            id="queue-package"
            phx-submit="queue_package"
            class="mt-5 flex flex-col gap-3"
          >
            <div class="flex flex-col gap-3 sm:flex-row sm:items-end">
              <div class="w-full sm:max-w-sm">
                <.input
                  field={@queue_form[:package_name]}
                  label="Package name"
                  autocomplete="off"
                  spellcheck="false"
                  placeholder="nerves_system_rpi4"
                  class="input input-bordered w-full font-mono"
                />
              </div>
              <button type="submit" class="btn btn-primary mb-2">Queue scan</button>
            </div>
            <.input
              field={@queue_form[:force]}
              type="checkbox"
              label="Force a rebuild even if this version was already built. Costs a full firmware build."
            />
          </.form>
        </div>
      </section>

      <section class="card border border-base-300 bg-base-100 shadow-sm">
        <div class="card-body">
          <div class="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
            <div>
              <h2 class="card-title">Anonymous approvals</h2>
              <p class="mt-1 text-sm leading-6 text-base-content/70">
                These requests need a human check before queue promotion.
              </p>
            </div>
            <span class="badge badge-outline w-fit">Manual review</span>
          </div>

          <div id="approvals-table" class="mt-5">
            <Cinder.collection
              id="approvals"
              query={@approvals_query}
              actor={@current_user}
              selectable
              page_size={25}
              empty_message="No anonymous requests are waiting for approval."
            >
              <:col :let={r} field="package_name" label="Package" filter sort class="font-mono">
                {r.package_name}
              </:col>
              <:col :let={r} field="subject" label="Requested by">{r.subject || "anonymous"}</:col>
              <:col :let={r} field="inserted_at" label="Submitted" sort>
                {format_datetime(r.inserted_at)}
              </:col>
              <:col :let={r} label="Action">
                <div class="flex justify-end gap-2">
                  <button
                    id={"reject-#{r.id}"}
                    type="button"
                    phx-click="reject"
                    phx-value-id={r.id}
                    class="btn btn-sm btn-ghost text-error"
                  >
                    Reject
                  </button>
                  <button
                    id={"approve-#{r.id}"}
                    type="button"
                    phx-click="approve"
                    phx-value-id={r.id}
                    class="btn btn-sm btn-primary"
                  >
                    Approve
                  </button>
                </div>
              </:col>
              <:bulk_action
                action={@bulk.approve}
                label="Approve ({count})"
                variant={:primary}
                on_success={:bulk_done}
                on_error={:bulk_failed}
              />
              <:bulk_action
                action={@bulk.reject}
                label="Reject ({count})"
                variant={:danger}
                confirm="Reject {count} requests?"
                on_success={:bulk_done}
                on_error={:bulk_failed}
              />
            </Cinder.collection>
          </div>
        </div>
      </section>

      <section class="card border border-base-300 bg-base-100 shadow-sm">
        <div class="card-body">
          <div class="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
            <div>
              <h2 class="card-title">Current queue</h2>
              <p class="mt-1 text-sm leading-6 text-base-content/70">
                Accepted portal requests are shown oldest first. Pending anonymous requests stay out of this list until approved.
                Only queued requests can be selected for a bulk move: an accepted one has no build job yet.
              </p>
            </div>
            <span class="badge badge-primary w-fit">Accepted</span>
          </div>

          <%!-- Only this table gets `url_state`: Cinder 0.17 has no per-table
               URL prefix, so two tables would share `page`, `sort` and the
               `package_name` filter. --%>
          <div id="queue-table" class="mt-5">
            <Cinder.collection
              id="queue"
              query={@queue_query}
              actor={@current_user}
              url_state={@url_state}
              selectable={&(&1.status == :queued)}
              page_size={50}
              query_opts={[load: [:queue_position]]}
              empty_message="No accepted portal requests are currently queued."
            >
              <:col :let={r} field="package_name" label="Package" filter sort class="font-mono">
                {r.package_name}
              </:col>
              <:col
                :let={r}
                field="source"
                label="Verification"
                filter={[type: :select, options: source_options()]}
              >
                {verification_label(r.source)}
              </:col>
              <:col
                :let={r}
                field="status"
                label="Status"
                filter={[type: :select, options: [{"Accepted", "accepted"}, {"Queued", "queued"}]]}
              >
                <span class="badge badge-outline">{request_status_label(r.status)}</span>
              </:col>
              <:col :let={r} field="subject" label="Subject" filter>{r.subject || "-"}</:col>
              <:col :let={r} field="inserted_at" label="Submitted" sort>
                {format_datetime(r.inserted_at)}
              </:col>
              <:col :let={r} label="Queue position">
                <div :if={r.queue_position} class="flex items-center justify-end gap-2">
                  <span class="badge badge-ghost font-mono" title={r.queue_position.state}>
                    P{r.queue_position.priority}
                  </span>
                  <button
                    id={"move-up-#{r.id}"}
                    type="button"
                    phx-click="reprioritise"
                    phx-value-id={r.id}
                    phx-value-direction="up"
                    class="btn btn-xs btn-ghost"
                    disabled={not r.queue_position.adjustable? or r.queue_position.priority == 0}
                    title="Run sooner"
                  >
                    &uarr;
                  </button>
                  <button
                    id={"move-down-#{r.id}"}
                    type="button"
                    phx-click="reprioritise"
                    phx-value-id={r.id}
                    phx-value-direction="down"
                    class="btn btn-xs btn-ghost"
                    disabled={not r.queue_position.adjustable? or r.queue_position.priority == 9}
                    title="Run later"
                  >
                    &darr;
                  </button>
                </div>
                <span :if={!r.queue_position} class="text-sm text-base-content/50">building</span>
              </:col>
              <:bulk_action
                action={@bulk.move_up}
                label="Move up ({count})"
                on_success={:bulk_done}
                on_error={:bulk_failed}
              />
              <:bulk_action
                action={@bulk.move_down}
                label="Move down ({count})"
                variant={:secondary}
                on_success={:bulk_done}
                on_error={:bulk_failed}
              />
            </Cinder.collection>
          </div>
        </div>
      </section>
    </.admin_layout>
    """
  end

  defp source_options do
    ScanRequest
    |> Ash.Resource.Info.attribute(:source)
    |> Map.fetch!(:constraints)
    |> Keyword.fetch!(:one_of)
    |> Enum.map(&{verification_label(&1), to_string(&1)})
  end
end
