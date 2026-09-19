defmodule PortalWeb.UserAuth do
  @moduledoc """
  Session handling for logins, and the LiveView `on_mount` hook that assigns
  auth-derived state.

  Controllers derive `current_user` from `get_session(conn, :user_id)` via
  `Portal.Accounts.get_user/1`. LiveViews mounted outside a controller need
  the same assign so `<Layouts.app current_user={@current_user} ...>` shows
  the signed-in nav state instead of always rendering Login/Register.

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
    # How this session was *established*, as opposed to `:reauth_method`,
    # which records the most recent step-up and is overwritten on every one.
    # `PortalWeb.Plugs.RequireAdmin` needs the former: a recovery-code step-up
    # at `/settings/security` must not revoke admin access mid-session, and a
    # password login must not gain it.
    |> put_session(:login_method, method)
    |> mark_reauth(method)
    |> drop_pending()
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
    |> delete_session(:user_id)
    |> delete_session(:login_method)
    |> delete_session(:reauth_method)
    |> delete_session(:reauth_at)
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
  for the five-minute rule to live.
  """
  @spec pending_user(Plug.Conn.t()) :: {:ok, User.t()} | :error
  def pending_user(conn) do
    with user_id when is_binary(user_id) <- get_session(conn, :pending_user_id),
         started when is_integer(started) <- get_session(conn, :pending_started_at),
         elapsed = System.system_time(:second) - started,
         true <- elapsed >= 0 and elapsed <= @pending_ttl_seconds,
         {:ok, %User{} = user} <- Portal.Accounts.get_user(user_id) do
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
      not Portal.Accounts.admin?(user) -> ~p"/request-scan"
      not Portal.Accounts.Mfa.admin_satisfied?(user) -> ~p"/settings/security"
      method == :passkey -> ~p"/admin"
      true -> ~p"/settings/security"
    end
  end

  defp current_user_from_session(%{"user_id" => user_id}) when is_binary(user_id) do
    case Portal.Accounts.get_user(user_id) do
      {:ok, user} -> user
      _ -> nil
    end
  end

  defp current_user_from_session(_session), do: nil
end
