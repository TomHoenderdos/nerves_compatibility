defmodule PortalWeb.Admin.BuildersLive do
  @moduledoc """
  Admin Builders tab: the remote routing policy, enrolment tokens, the
  enrolled builders with their publishing switch and revoke, and the recent
  remote leases with, for the failed ones, a requeue to the remote queue and
  a "Requeue locally" that builds the package on this host instead.

  The page follows the builders live: `Portal.Builders.Leases` and
  `Portal.Admin` announce changes on `Portal.AdminEvents`' `:builders` topic
  and the page refetches, at most once per throttle window.

  Each click re-runs the admin policy against a freshly loaded user, as
  `PortalWeb.Admin.QueueLive` does: an admin demoted or stripped of their
  passkey while the page is open is refused on the next click.
  """
  use PortalWeb, :live_view

  import PortalWeb.AdminComponents
  import PortalWeb.Admin.LiveAuth, except: [as_admin: 2]

  alias Portal.Builders
  alias Portal.Builders.{Images, Leases, Routing}
  alias PortalWeb.AdminMessages

  @recent_leases 50

  @impl true
  def mount(_params, session, socket) do
    if connected?(socket), do: Portal.AdminEvents.subscribe(:builders)

    {:ok,
     socket
     |> assign(
       page_title: "Admin",
       page_description: "Administration.",
       user_id: session["user_id"],
       login_method: session["login_method"],
       token: nil,
       token_form: to_form(%{"name" => ""})
     )
     |> assign_remote_form()
     |> load()}
  end

  # The form is set from the stored settings on mount and after a save only,
  # so a refresh from another admin's change does not wipe what is typed.
  defp assign_remote_form(socket) do
    settings = Portal.Settings.get()

    assign(socket,
      remote_form:
        to_form(
          %{
            "remote_mode" => Atom.to_string(settings.remote_mode),
            "remote_backlog_threshold" => Integer.to_string(settings.remote_backlog_threshold)
          },
          as: :remote
        )
    )
  end

  defp load(socket) do
    builders = Builders.list_builders()

    # Revoked builders too: `Portal.Builders.revoke/1` commits the status
    # before revoking the runs, so one that failed partway is revoked with
    # runs still open, and gets its button back to finish the job.
    previews = Map.new(builders, &{&1.id, Builders.revoke_preview(&1)})

    assign(socket,
      builders: builders,
      builder_names: Map.new(builders, &{&1.id, &1.name}),
      previews: previews,
      runs: Builders.runs_count(),
      throughput: Builders.throughput_24h(),
      leases: Leases.recent(@recent_leases),
      counts: Leases.counts(),
      settings: Portal.Settings.get(),
      remote: %{
        enabled?: Routing.remote_enabled?(),
        backlog: Routing.local_backlog(),
        image: Images.worker_image()
      },
      now: DateTime.utc_now()
    )
  end

  @impl true
  def handle_event("new_token", params, socket) do
    as_admin(socket, fn socket, user ->
      name = string_param(params, "name")

      case Portal.Admin.create_builder_token(name, user) do
        {:ok, %{token: token, record: record}} ->
          socket
          |> assign(
            token: %{name: record.name, value: token},
            token_form: to_form(%{"name" => ""})
          )
          |> done(:info, "Enrolment token for #{record.name} minted. It is valid for 24 hours.")

        {:error, reason} ->
          socket
          |> assign(token_form: to_form(%{"name" => name}))
          |> done(:error, error_message(reason))
      end
    end)
  end

  # The button carries the state it offers to switch to, which is what the
  # admin saw: a second click on a stale page repeats the same intent rather
  # than flipping it back.
  def handle_event("toggle_publishing", params, socket) do
    as_admin(socket, fn socket, user ->
      publishing = params["publishing"] == "true"

      case Portal.Admin.set_builder_publishing(string_param(params, "id"), publishing, user) do
        {:ok, builder} -> done(socket, :info, publishing_message(builder))
        {:error, reason} -> done(socket, :error, error_message(reason))
      end
    end)
  end

  def handle_event("revoke", params, socket) do
    as_admin(socket, fn socket, user ->
      case Portal.Admin.revoke_builder(string_param(params, "id"), user) do
        {:ok, %{builder: builder, runs_revoked: runs, packages: packages}} ->
          done(
            socket,
            :info,
            "Revoked #{builder.name}: #{runs} runs revoked, " <>
              "#{length(packages)} packages queued for a local rebuild."
          )

        {:error, reason} ->
          done(socket, :error, error_message(reason))
      end
    end)
  end

  def handle_event("requeue", params, socket) do
    as_admin(socket, fn socket, _user ->
      case Portal.Admin.requeue_lease(string_param(params, "id")) do
        {:ok, lease} -> done(socket, :info, "Requeued #{lease.package} #{lease.version}.")
        {:error, reason} -> done(socket, :error, error_message(reason))
      end
    end)
  end

  def handle_event("requeue_local", params, socket) do
    as_admin(socket, fn socket, user ->
      case Portal.Admin.requeue_lease_locally(string_param(params, "id"), user) do
        {:ok, job} ->
          done(
            socket,
            :info,
            "Queued a local build of #{job.args["package"]} #{job.args["version"]}."
          )

        {:error, reason} ->
          done(socket, :error, error_message(reason))
      end
    end)
  end

  def handle_event("save_remote", params, socket) do
    as_admin(socket, fn socket, _user ->
      remote = if is_map(params["remote"]), do: params["remote"], else: %{}

      case Portal.Admin.update_remote_settings(remote) do
        {:ok, _setting} ->
          socket |> assign_remote_form() |> done(:info, "Remote routing saved.")

        {:error, reason} ->
          socket
          |> assign(remote_form: to_form(remote, as: :remote))
          |> done(:error, error_message(reason))
      end
    end)
  end

  @impl true
  def handle_info({:admin_changed, :builders}, socket) do
    case Portal.AdminEvents.throttle(socket, :builders) do
      {:refresh, socket} -> {:noreply, load(socket)}
      {:skip, socket} -> {:noreply, socket}
    end
  end

  def handle_info({:admin_refresh, :builders}, socket), do: {:noreply, load(socket)}

  defp as_admin(socket, fun) do
    PortalWeb.Admin.LiveAuth.as_admin(socket, fn socket, user ->
      # A token is shown for the action that minted it only.
      fun.(assign(socket, :token, nil), user)
    end)
  end

  defp done(socket, kind, message) do
    {:noreply, socket |> put_flash(kind, message) |> load()}
  end

  # `:not_found` reads "Request was not found." on the queue page; here the
  # id is a builder's or a lease's.
  defp error_message(:not_found), do: "That builder or lease no longer exists."
  defp error_message(reason), do: AdminMessages.error(reason)

  defp revoke_confirm(builder, %{runs: runs, packages: packages}),
    do:
      "Revoke #{builder.name}? #{runs} runs will be revoked and " <>
        "#{length(packages)} packages rebuilt locally."

  defp mib(bytes), do: Float.round(bytes / 1_048_576, 1)

  defp age(nil, _now), do: "-"

  defp age(%DateTime{} = at, now) do
    seconds = max(DateTime.diff(now, at, :second), 0)

    cond do
      seconds < 60 -> "#{seconds}s ago"
      seconds < 3600 -> "#{div(seconds, 60)}m ago"
      seconds < 86_400 -> "#{div(seconds, 3600)}h ago"
      true -> "#{div(seconds, 86_400)}d ago"
    end
  end

  defp lease_badge(:queued), do: "badge-ghost"
  defp lease_badge(:leased), do: "badge-info"
  defp lease_badge(:uploading), do: "badge-info"
  defp lease_badge(:done), do: "badge-success"
  defp lease_badge(:failed), do: "badge-error"

  @impl true
  def render(assigns) do
    ~H"""
    <.admin_layout flash={@flash} current_user={@current_user} section={:builders} title="Builders">
      <:subtitle>Remote builders, their enrolment and the jobs leased to them.</:subtitle>

      <section id="remote-settings" class="card border border-base-300 bg-base-100 shadow-sm">
        <div class="card-body">
          <h2 class="card-title text-lg">Remote routing</h2>
          <dl class="mt-2 grid grid-cols-1 gap-3 text-sm sm:grid-cols-3">
            <div>
              <dt class="text-base-content/60">Remote builds now</dt>
              <dd id="remote-enabled" class="font-medium">
                {if @remote.enabled?, do: "On", else: "Off"}
              </dd>
            </div>
            <div>
              <dt class="text-base-content/60">Local backlog</dt>
              <dd id="local-backlog" class="font-medium">
                {@remote.backlog} jobs (threshold {@settings.remote_backlog_threshold})
              </dd>
            </div>
            <div>
              <dt class="text-base-content/60">Worker image</dt>
              <dd id="worker-image" class="font-medium">
                <%= if @remote.image do %>
                  <span class="break-all font-mono text-xs">
                    {@remote.image.name}@{@remote.image.digest}
                  </span>
                <% else %>
                  <span class="text-warning">Unknown; remote builds stay off.</span>
                <% end %>
              </dd>
            </div>
          </dl>

          <.form
            for={@remote_form}
            id="remote-settings-form"
            phx-submit="save_remote"
            class="mt-4 flex flex-col gap-3 sm:flex-row sm:items-end"
          >
            <div class="sm:w-48">
              <.input
                field={@remote_form[:remote_mode]}
                type="select"
                label="Mode"
                options={[{"Auto (above the backlog)", "auto"}, {"On", "on"}, {"Off", "off"}]}
              />
            </div>
            <div class="sm:w-48">
              <.input
                field={@remote_form[:remote_backlog_threshold]}
                type="number"
                min="0"
                label="Backlog threshold"
              />
            </div>
            <div class="mb-2">
              <button id="save-remote" type="submit" class="btn btn-primary btn-sm">Save</button>
            </div>
          </.form>
        </div>
      </section>

      <section id="new-token" class="card border border-base-300 bg-base-100 shadow-sm">
        <div class="card-body">
          <h2 class="card-title text-lg">New enrolment token</h2>
          <p class="text-sm text-base-content/70">
            A one-time token a new machine enrols with, valid for 24 hours.
          </p>
          <.form
            for={@token_form}
            id="new-token-form"
            phx-submit="new_token"
            class="mt-2 flex flex-col gap-3 sm:flex-row sm:items-end"
          >
            <div class="sm:w-72">
              <.input
                field={@token_form[:name]}
                label="Builder name"
                autocomplete="off"
                spellcheck="false"
                placeholder="build-box-1"
                class="input input-bordered w-full font-mono"
              />
            </div>
            <div class="mb-2">
              <button id="mint-token" type="submit" class="btn btn-primary btn-sm">
                Mint token
              </button>
            </div>
          </.form>

          <div
            :if={@token}
            id="enrolment-token-box"
            class="mt-4 rounded-xl border border-warning/40 bg-warning/10 p-3 text-sm"
          >
            <p>
              Enrolment token for <span class="font-semibold">{@token.name}</span>.
              Copy it now; it is not stored.
            </p>
            <code
              id="enrolment-token"
              class="mt-2 block select-all break-all rounded bg-base-100 px-2 py-1 font-mono"
              phx-no-format
            >{@token.value}</code>
          </div>
        </div>
      </section>

      <section id="admin-builders" class="card border border-base-300 bg-base-100 shadow-sm">
        <div class="card-body">
          <h2 class="card-title text-lg">Builders</h2>
          <div class="overflow-x-auto">
            <table id="builders" class="table table-sm">
              <thead>
                <tr>
                  <th>Name</th>
                  <th>Status</th>
                  <th>Slots</th>
                  <th>Last seen</th>
                  <th>Agent</th>
                  <th>Egress</th>
                  <th>Publishing</th>
                  <th>Cert expires</th>
                  <th>Runs</th>
                  <th>Last 24 h</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                <tr :if={@builders == []}>
                  <td colspan="11" class="text-sm text-base-content/60">
                    No builders are enrolled.
                  </td>
                </tr>
                <tr :for={b <- @builders} id={"builder-#{b.id}"}>
                  <td class="font-medium">{b.name}</td>
                  <td>
                    <span class={[
                      "badge badge-sm",
                      if(b.status == :revoked, do: "badge-error", else: "badge-success")
                    ]}>
                      {b.status}
                    </span>
                  </td>
                  <td>{b.slots}</td>
                  <td class="whitespace-nowrap">{age(b.last_seen_at, @now)}</td>
                  <td class="font-mono text-xs">{b.last_version || "-"}</td>
                  <td>{b.egress_status || "unknown"}</td>
                  <td>
                    <button
                      id={"toggle-publishing-#{b.id}"}
                      type="button"
                      phx-click="toggle_publishing"
                      phx-value-id={b.id}
                      phx-value-publishing={to_string(!b.publishing)}
                      disabled={b.status == :revoked}
                      class={[
                        "btn btn-xs whitespace-nowrap",
                        if(b.publishing, do: "btn-success", else: "btn-ghost")
                      ]}
                    >
                      {if b.publishing, do: "Publishing", else: "Not publishing"}
                    </button>
                  </td>
                  <td class="whitespace-nowrap">{format_datetime(b.cert_expires_at)}</td>
                  <td>{Map.get(@runs, b.id, 0)}</td>
                  <td id={"throughput-#{b.id}"} class="whitespace-nowrap">
                    {throughput_line(Map.get(@throughput, b.id))}
                  </td>
                  <td class="text-right">
                    <button
                      :if={b.status != :revoked or @previews[b.id].runs > 0}
                      id={"revoke-#{b.id}"}
                      type="button"
                      phx-click="revoke"
                      phx-value-id={b.id}
                      data-confirm={revoke_confirm(b, Map.fetch!(@previews, b.id))}
                      class="btn btn-xs btn-error whitespace-nowrap"
                    >
                      {if b.status == :revoked, do: "Finish revoke", else: "Revoke"}
                    </button>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </section>

      <section id="admin-leases" class="card border border-base-300 bg-base-100 shadow-sm">
        <div class="card-body">
          <h2 class="card-title text-lg">Recent leases</h2>
          <p id="lease-counts" class="text-sm text-base-content/70">
            {@counts.queued} queued, {@counts.leased} leased, {@counts.uploading} uploading, {@counts.done} done, {@counts.failed} failed.
          </p>
          <div class="overflow-x-auto">
            <table id="leases" class="table table-sm">
              <thead>
                <tr>
                  <th>Package</th>
                  <th>State</th>
                  <th>Phase</th>
                  <th>Builder</th>
                  <th>Attempt</th>
                  <th>Uploaded</th>
                  <th>Heartbeat</th>
                  <th>Log</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                <tr :if={@leases == []}>
                  <td colspan="9" class="text-sm text-base-content/60">No remote leases yet.</td>
                </tr>
                <tr :for={l <- @leases} id={"lease-#{l.id}"}>
                  <td class="whitespace-nowrap">
                    <span class="font-medium">{l.package}</span>
                    <span class="font-mono text-xs text-base-content/60">{l.version}</span>
                  </td>
                  <td>
                    <span class={["badge badge-sm", lease_badge(l.state)]}>{l.state}</span>
                  </td>
                  <td>{l.phase || "-"}</td>
                  <td>{Map.get(@builder_names, l.builder_id, "-")}</td>
                  <td>{l.attempt}/{l.max_attempts}</td>
                  <td class="whitespace-nowrap">{mib(l.bytes_uploaded)} MiB</td>
                  <td class="whitespace-nowrap">{age(l.heartbeat_at, @now)}</td>
                  <td>
                    <details :if={l.log_tail || l.error} id={"lease-log-#{l.id}"}>
                      <summary class="cursor-pointer text-xs">{l.error || "log"}</summary>
                      <pre
                        :if={l.log_tail}
                        class="mt-2 max-h-64 max-w-xl overflow-auto whitespace-pre-wrap rounded bg-base-200 p-2 text-xs"
                      >{l.log_tail}</pre>
                    </details>
                  </td>
                  <td class="text-right">
                    <div
                      :if={l.state in [:failed, :queued] and l.error != Leases.requeued_locally()}
                      class="flex justify-end gap-1"
                    >
                      <button
                        :if={l.state == :failed and l.error != "non-Hex dep"}
                        id={"requeue-#{l.id}"}
                        type="button"
                        phx-click="requeue"
                        phx-value-id={l.id}
                        class="btn btn-xs btn-ghost whitespace-nowrap"
                      >
                        Requeue
                      </button>
                      <button
                        id={"requeue-local-#{l.id}"}
                        type="button"
                        phx-click="requeue_local"
                        phx-value-id={l.id}
                        class="btn btn-xs btn-ghost whitespace-nowrap"
                      >
                        Requeue locally
                      </button>
                    </div>
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

  defp throughput_line(nil), do: "-"
  defp throughput_line(%{done: done, failed: failed}), do: "#{done} done, #{failed} failed"

  defp publishing_message(builder) do
    verb = if builder.publishing, do: "now publishes", else: "no longer publishes"
    "#{builder.name} #{verb} its files."
  end
end
