defmodule PortalWeb.UserAuth do
  @moduledoc """
  Session handling for logins, and the LiveView `on_mount` hook that assigns
  auth-derived state.

  Controllers derive `current_user` from the session through
  `current_user/1`, LiveViews through the `:assign_current_user` hook, and
  `PortalWeb.Plugs.RequireAdmin` through the same
  `Portal.Accounts.session_user/2`. LiveViews mounted outside a controller
  need the assign so `<Layouts.app current_user={@current_user} ...>` shows
  the signed-in nav state instead of always rendering Login/Register.

  ## Revoking sessions

  The session store is the signed cookie, so no server-side session exists to
  delete. Each login stamps `:session_started_at` instead, and a session that
  started before its user's `sessions_valid_after` is treated as signed out
  everywhere `Portal.Accounts.session_user/2` is asked
  (`Portal.Accounts.revoke_sessions/1`). An admin password reset, an admin
  revoke, a password change, a passkey removal and "sign out everywhere" all
  revoke; the ones a user does to their own account re-stamp the session they
  did it from (`restamp_session/2`).

  Plain sign-out is not one of them. It clears this browser's cookie and
  disconnects the user's live sockets, and the user's other browsers stay
  signed in. A copy of the cookie taken before sign-out stays valid until the
  user's sessions are next revoked.

  A half-finished login lives under `:pending_user_id`, never `:user_id`, so
  it grants nothing anywhere: every plug and hook reads `:user_id` alone.
  """

  use PortalWeb, :verified_routes

  import Phoenix.Component, only: [assign: 3]
  import Plug.Conn, except: [assign: 3]

  alias Portal.Accounts.User

  @pending_ttl_seconds 300

  def on_mount(:assign_current_user, _params, session, socket) do
    {:cont, assign(socket, :current_user, current_user_from_session(session))}
  end

  @doc """
  Signs `user` in, having proven `method`.
  """
  @spec complete_login(Plug.Conn.t(), User.t(), atom()) :: Plug.Conn.t()
  def complete_login(conn, %User{} = user, method) do
    conn
    # `configure_session(renew: true)` rotates the session id. Under this app's
    # `store: :cookie` (see `endpoint.ex`) that is a no-op: the session *is* the
    # signed cookie value, `Plug.Session.COOKIE.delete/3` does nothing, and the
    # emitted cookie is a pure function of session contents either way. A
    # cookie fixated before login is inert here because of the store, not
    # because of this line. No test guards this call, and none can -- removing
    # it changes no observable behaviour. It is kept as defence in depth: it
    # becomes load-bearing the day the store becomes server-side, precisely
    # the day nobody will remember to add it.
    |> configure_session(renew: true)
    |> put_session(:user_id, user.id)
    # When this session started, for `Portal.Accounts.session_user/2` to hold
    # against the user's `sessions_valid_after`. Microseconds, matching it.
    |> put_session(:session_started_at, System.system_time(:microsecond))
    # Names this session's live sockets, so sign-out and a loss of access
    # can disconnect them (`Portal.Accounts.disconnect_live_sockets/1`).
    |> put_session(:live_socket_id, Portal.Accounts.live_socket_id(user.id))
    # How this session was *established*, as opposed to `:reauth_method`,
    # which records the most recent step-up and is overwritten on every one.
    # `PortalWeb.Plugs.RequireAdmin` needs the former: a recovery-code step-up
    # at `/settings/security` must not revoke admin access mid-session, and a
    # password login must not gain it.
    |> put_session(:login_method, method)
    |> mark_reauth(method)
    |> drop_pending()
    # A provider sign-in abandoned at choose-username leaves its identity in
    # the session. Whatever route this login took, that identity must not
    # outlive it and later mint an account from this session.
    |> delete_session(:pending_identity)
  end

  @doc """
  The user this conn's session belongs to, or `nil` if it is signed out or
  revoked (`Portal.Accounts.session_user/2`).
  """
  @spec current_user(Plug.Conn.t()) :: User.t() | nil
  def current_user(conn) do
    Portal.Accounts.session_user(
      get_session(conn, :user_id),
      get_session(conn, :session_started_at)
    )
  end

  @doc """
  Keeps this session valid across a revocation the user made from it.

  Call it after `Portal.Accounts.revoke_sessions/1`, or any change that
  revokes, ideally with the user that change returned. The new start is now,
  or the user's `sessions_valid_after` should the clock have stepped back
  past it.
  """
  @spec restamp_session(Plug.Conn.t(), User.t() | nil) :: Plug.Conn.t()
  def restamp_session(conn, user \\ nil) do
    now = System.system_time(:microsecond)

    started =
      case user do
        %User{sessions_valid_after: %DateTime{} = cutoff} ->
          max(now, DateTime.to_unix(cutoff, :microsecond))

        _other ->
          now
      end

    put_session(conn, :session_started_at, started)
  end

  @doc """
  Drops what signs this session in, leaving the CSRF token and the flash.

  For a session `current_user/1` refused: it grants nothing either way, and
  clearing it keeps a stale cookie from being carried around.
  """
  @spec drop_login(Plug.Conn.t()) :: Plug.Conn.t()
  def drop_login(conn) do
    conn
    |> delete_session(:user_id)
    |> delete_session(:session_started_at)
    |> delete_session(:live_socket_id)
    |> delete_session(:login_method)
    |> delete_session(:reauth_method)
    |> delete_session(:reauth_at)
  end

  @doc """
  The credential this session was signed in with, if any.
  """
  @spec login_method(Plug.Conn.t()) :: atom() | nil
  def login_method(conn), do: get_session(conn, :login_method)

  @doc """
  Records that `method` was proven just now, starting a fresh step-up window.
  """
  @spec mark_reauth(Plug.Conn.t(), atom()) :: Plug.Conn.t()
  def mark_reauth(conn, method) when is_atom(method) do
    conn
    |> put_session(:reauth_method, method)
    |> put_session(:reauth_at, System.system_time(:second))
  end

  @spec reauth_method(Plug.Conn.t()) :: atom() | nil
  def reauth_method(conn), do: get_session(conn, :reauth_method)

  @spec reauth_at(Plug.Conn.t()) :: integer() | nil
  def reauth_at(conn), do: get_session(conn, :reauth_at)

  @doc """
  Parks a password-authenticated user until they clear the second step.
  """
  @spec start_pending(Plug.Conn.t(), User.t()) :: Plug.Conn.t()
  def start_pending(conn, %User{} = user) do
    conn
    |> drop_login()
    |> put_session(:pending_user_id, user.id)
    |> put_session(:pending_started_at, System.system_time(:second))
  end

  @spec drop_pending(Plug.Conn.t()) :: Plug.Conn.t()
  def drop_pending(conn) do
    conn
    |> delete_session(:pending_user_id)
    |> delete_session(:pending_started_at)
  end

  @doc """
  The user waiting on a second factor, if the pending session is still valid.

  Expiry is checked here rather than at the call sites so there is one place
  for the five-minute rule to live, and so is revocation: a pending sign-in
  that started before the user's `sessions_valid_after` is refused.
  """
  @spec pending_user(Plug.Conn.t()) :: {:ok, User.t()} | :error
  def pending_user(conn) do
    with user_id when is_binary(user_id) <- get_session(conn, :pending_user_id),
         started when is_integer(started) <- get_session(conn, :pending_started_at),
         elapsed = System.system_time(:second) - started,
         true <- elapsed >= 0 and elapsed <= @pending_ttl_seconds,
         {:ok, %User{} = user} <- Portal.Accounts.get_user(user_id),
         # A revocation inside the five minutes ends the half-finished
         # sign-in too, or its second step would mint a fresh session.
         # The start is whole seconds, so it is floored: a sign-in begun in
         # the same second as a revocation is refused, never let through.
         true <- Portal.Accounts.session_current?(user, started * 1_000_000) do
      {:ok, user}
    else
      _ -> :error
    end
  end

  # Where signing in drops you. An admin signs in to administrate -- the queue,
  # the pending approvals -- not to request a scan of somebody else's package,
  # so sending them to the public request form is a detour every single time.
  #
  # This also repairs the one place the gate sends people nowhere useful:
  # `RequireAdmin` bounces an unauthenticated visitor to `/login`, and before
  # this they landed on `/request-scan` having asked for `/admin`.
  # An admin who has not enrolled a passkey is a third case, not the first
  # one. Sending them to `/admin` means a redirect, a second redirect and an
  # error flash on every single login, forever -- which reads as a failure
  # rather than the prompt it is. They go straight to the page that fixes it.
  #
  # An enrolled admin who signed in with something other than the passkey is a
  # fourth case, and for the same reason: `RequireAdmin` now refuses that
  # session, so routing it to `/admin` would be the same bounce-and-flash loop.
  # They go to `/settings/security`, where the passkey sign-in prompt is.
  @spec landing_path(User.t(), atom() | nil) :: String.t()
  def landing_path(user, method) do
    cond do
      user.password_reset_required -> ~p"/settings"
      not Portal.Accounts.admin?(user) -> ~p"/request-scan"
      not Portal.Accounts.Mfa.admin_satisfied?(user) -> ~p"/settings/security"
      method == :passkey -> ~p"/admin"
      true -> ~p"/settings/security"
    end
  end

  # `live_session`'s session map is the cookie session as the page was
  # rendered, string-keyed. A connected mount presents it again from the
  # page, not from the cookie, so it is checked here as well as on the
  # request that rendered it.
  defp current_user_from_session(session) do
    Portal.Accounts.session_user(session["user_id"], session["session_started_at"])
  end
end
