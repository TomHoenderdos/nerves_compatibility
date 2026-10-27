defmodule PortalWeb.Admin.UsersLive do
  @moduledoc """
  Admin Users tab: every account in a Cinder table, with grant/revoke admin
  and password reset. Those three need a passkey confirmed within
  `Portal.Accounts.Mfa.reauth_window_seconds/0`; the confirmation time comes
  from the session the page was rendered with and is re-checked on every
  click, so a page left open past the window stops working rather than
  carrying the step-up forward.

  Each click also re-runs the admin policy against a freshly loaded user, as
  the controller actions this replaces did on every request: an admin demoted
  or stripped of their passkey while the page is open is refused and
  redirected on the next click, not when the socket happens to reconnect.
  """
  use PortalWeb, :live_view

  import PortalWeb.AdminComponents
  import PortalWeb.Admin.LiveAuth

  alias Portal.Accounts.Mfa
  alias PortalWeb.AdminMessages

  @impl true
  def mount(_params, session, socket) do
    {:ok,
     assign(socket,
       page_title: "Admin",
       page_description: "Administration.",
       # Read from the signed session, which keeps the types
       # `PortalWeb.UserAuth` stored: atoms for the methods, integer seconds
       # for the time. `Mfa.reauth_fresh?/3` compares against exactly those.
       user_id: session["user_id"],
       login_method: session["login_method"],
       session_started_at: session["session_started_at"],
       reauth_method: session["reauth_method"],
       reauth_at: session["reauth_at"],
       temporary_password: nil,
       # Admins first, then by username, as the controller page listed them.
       # Cinder takes the query's sort as the table's default and drops it
       # once a header sort is chosen.
       users_query: Ash.Query.sort(Portal.Accounts.User, is_admin: :desc, username: :asc)
     )}
  end

  @impl true
  def handle_params(params, uri, socket) do
    {:noreply, Cinder.UrlSync.handle_params(sane_page(params), uri, socket)}
  end

  @impl true
  def handle_event("grant_admin", params, socket) do
    stepped_up(socket, fn socket, user ->
      case Portal.Admin.grant_admin(string_param(params, "username"), user) do
        {:ok, granted} -> done(socket, :info, "#{granted.username} is now an admin.")
        {:error, reason} -> done(socket, :error, AdminMessages.error(reason))
      end
    end)
  end

  def handle_event("revoke_admin", params, socket) do
    stepped_up(socket, fn socket, user ->
      case Portal.Admin.revoke_admin(string_param(params, "id"), user) do
        {:ok, revoked} -> done(socket, :info, "#{revoked.username} is no longer an admin.")
        {:error, reason} -> done(socket, :error, AdminMessages.error(reason))
      end
    end)
  end

  # The temporary password goes into this page's assigns and nowhere else:
  # not the flash, whose cookie is signed but readable and survives into the
  # next request, and not the log.
  def handle_event("reset_password", params, socket) do
    stepped_up(socket, fn socket, user ->
      case Portal.Admin.reset_password(string_param(params, "username"), user) do
        {:ok, target, temp} ->
          socket
          |> assign(:temporary_password, %{username: target.username, password: temp})
          |> done(
            :info,
            "#{target.username} has a temporary password. They must choose a new one when they sign in."
          )

        {:error, reason} ->
          done(socket, :error, AdminMessages.error(reason))
      end
    end)
  end

  # Granting or revoking admin changes who can do everything on this page, so
  # it needs the step-up the security settings use on top of the admin
  # policy. Without it, a stolen admin session could quietly hand out admin.
  defp stepped_up(socket, fun) do
    as_admin(socket, fn socket, user ->
      # A temporary password is shown for the action that made it only, as
      # it was when each action rendered its own response.
      socket = assign(socket, :temporary_password, nil)

      if Mfa.reauth_fresh?(user, socket.assigns.reauth_method, socket.assigns.reauth_at) do
        fun.(socket, user)
      else
        refuse(socket, %{
          to: ~p"/settings/security",
          flash: "Confirm your passkey on this page first, then come back to change admins."
        })
      end
    end)
  end

  @impl true
  def handle_info({:table_state_change, _table_id, encoded_state}, socket),
    do: table_state_change(socket, encoded_state)

  defp done(socket, kind, message) do
    {:noreply, socket |> put_flash(kind, message) |> Cinder.refresh_table("users")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.admin_layout flash={@flash} current_user={@current_user} section={:users} title="Users">
      <:subtitle>Every account, with admin access and password resets.</:subtitle>
      <section id="admin-users" class="card border border-base-300 bg-base-100 shadow-sm">
        <div class="card-body">
          <p class="text-sm leading-6 text-base-content/70">
            Granting, revoking and resetting need a passkey confirmed in the last {div(
              Portal.Accounts.Mfa.reauth_window_seconds(),
              60
            )} minutes on <.link navigate={~p"/settings/security"} class="link">your security settings</.link>.
            A new admin can only open the admin pages once they have added a passkey. A
            reset sets a random temporary password, shown once; pass it on yourself, and the
            user chooses a new one when they sign in. Second factors stay.
          </p>

          <div
            :if={@temporary_password}
            id="temporary-password"
            class="mt-4 rounded-xl border border-warning/40 bg-warning/10 p-3 text-sm"
          >
            Temporary password for <span class="font-semibold">{@temporary_password.username}</span>
            (shown only now): <code
              id="temporary-password-value"
              class="ml-1 select-all rounded bg-base-100 px-2 py-0.5 font-mono"
              phx-no-format
            >{@temporary_password.password}</code>
          </div>

          <div class="mt-4">
            <Cinder.collection
              id="users"
              query={@users_query}
              actor={@current_user}
              url_state={@url_state}
              page_size={50}
              query_opts={[load: [:passkey_count]]}
            >
              <:col :let={user} field="username" label="User" filter sort>
                <div class="font-medium">{user.username}</div>
                <div class="whitespace-nowrap text-xs text-base-content/50">
                  joined {format_datetime(user.inserted_at)}
                </div>
              </:col>
              <:col
                :let={user}
                field="hex_username"
                label="Accounts"
                filter
                class="whitespace-nowrap text-sm text-base-content/70"
              >
                <div :if={user.hex_username}>hex {user.hex_username}</div>
                <div :if={user.github_username}>github {user.github_username}</div>
                <div :if={!user.hex_username and !user.github_username}>-</div>
              </:col>
              <:col
                :let={user}
                field="password_set"
                label="Password"
                filter={[type: :boolean, labels: %{true => "Set", false => "No password"}]}
                class="whitespace-nowrap text-sm text-base-content/70"
              >
                {if user.password_set, do: "Set", else: "No password"}
              </:col>
              <:col
                :let={user}
                field="is_admin"
                label="Status"
                filter={[type: :boolean, labels: %{true => "Admin", false => "Not admin"}]}
                sort
              >
                <div class="flex flex-wrap gap-1">
                  <span :if={user.is_admin} class="badge badge-sm badge-primary">admin</span>
                  <span
                    :if={user.is_admin and user.passkey_count == 0}
                    class="badge badge-sm badge-warning"
                  >
                    needs a passkey
                  </span>
                  <span :if={user.password_reset_required} class="badge badge-sm badge-ghost">
                    temporary password
                  </span>
                </div>
              </:col>
              <:col :let={user} label="Actions" class="whitespace-nowrap">
                <div :if={user.id != @current_user.id} class="flex flex-nowrap justify-end gap-1">
                  <button
                    :if={!user.is_admin}
                    id={"grant-admin-#{user.id}"}
                    type="button"
                    phx-click="grant_admin"
                    phx-value-username={user.username}
                    class="btn btn-xs btn-ghost whitespace-nowrap"
                  >
                    Make admin
                  </button>
                  <button
                    :if={user.is_admin}
                    id={"revoke-admin-#{user.id}"}
                    type="button"
                    phx-click="revoke_admin"
                    phx-value-id={user.id}
                    class="btn btn-xs btn-ghost whitespace-nowrap"
                  >
                    Revoke admin
                  </button>
                  <button
                    id={"reset-password-#{user.id}"}
                    type="button"
                    phx-click="reset_password"
                    phx-value-username={user.username}
                    data-confirm={"Reset #{user.username}'s password?"}
                    class="btn btn-xs btn-warning whitespace-nowrap"
                  >
                    Reset password
                  </button>
                </div>
                <div
                  :if={user.id == @current_user.id}
                  class="text-right text-xs text-base-content/50"
                >
                  you
                </div>
              </:col>
            </Cinder.collection>
          </div>
        </div>
      </section>
    </.admin_layout>
    """
  end
end
