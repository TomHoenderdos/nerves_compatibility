defmodule PortalWeb.Plugs.RequireAdmin do
  @moduledoc """
  Halts the connection unless the current session belongs to an admin user
  who holds a passkey and signed in with it.

  Three entry points, one decision. `check/2` is the decision and takes a user
  (or `nil`) and the method that session authenticated with (or `nil`);
  `call/2` gates the `:admin` pipeline, `authorise/1` serves
  `PortalWeb.PageController`'s in-action admin checks, and `on_mount/4`
  re-runs it when a LiveView connects. They share `check/2` on purpose: the
  Oban dashboard and the buttons that approve scan requests, reorder the queue
  and start update checks are the same privilege, so a second hand-maintained
  copy of this policy would be a second place for it to rot.

  `on_mount/4` is not belt-and-braces. A router pipeline runs on the initial
  HTTP request and never again; the connected mount is authenticated by the
  signed session token from that dead render, which LiveView accepts for up to
  its 14-day max age. Without the hook, an admin who had `/admin/oban` open
  before this feature shipped keeps a working, reconnecting dashboard until
  the token ages out.

  The passkey requirement is enforced here rather than site-wide on purpose:
  an admin without one keeps full use of the rest of the portal and is sent to
  `/settings/security` to enrol, and a non-admin never sees the requirement at
  all. An authenticator app does not substitute. A TOTP code can be read out
  over the phone to someone claiming to be from the project; a passkey
  assertion is bound to the origin and cannot leave the browser.
  """

  import Plug.Conn
  import Phoenix.Controller

  use PortalWeb, :verified_routes

  alias Portal.Accounts.User

  @typedoc """
  Where a refused caller goes, and what they are told. Path and message rather
  than a conn or a socket, so the one decision can serve both.
  """
  @type refusal :: %{to: String.t(), flash: String.t()}

  def init(opts), do: opts

  def call(conn, _opts) do
    case authorise(conn) do
      {:ok, conn, user} -> assign(conn, :current_user, user)
      {:error, conn} -> halt(conn)
    end
  end

  @doc """
  The admin policy, for call sites that are controller actions rather than
  plugs.

  Returns the admin on success. On refusal the returned conn already carries
  the flash and the redirect; a controller returns it as-is, the plug halts it.
  """
  @spec authorise(Plug.Conn.t()) ::
          {:ok, Plug.Conn.t(), User.t()} | {:error, Plug.Conn.t()}
  def authorise(conn) do
    conn
    |> get_session(:user_id)
    |> load_user()
    |> check(get_session(conn, :login_method))
    |> case do
      {:ok, user} ->
        {:ok, conn, user}

      {:error, refusal} ->
        conn
        |> put_flash(:error, refusal.flash)
        |> redirect(to: refusal.to)
        |> then(&{:error, &1})
    end
  end

  @doc """
  The admin policy at LiveView mount, for routes a pipeline only sees once.

  `live_session`'s session map is the connection session merged with whatever
  the route adds, so the hook reads `"user_id"` the same way `authorise/1`
  reads `:user_id`.
  """
  def on_mount(:require_admin_passkey, _params, session, socket) do
    session
    |> Map.get("user_id")
    |> load_user()
    |> check(Map.get(session, "login_method"))
    |> case do
      {:ok, _user} ->
        {:cont, socket}

      {:error, refusal} ->
        socket
        |> Phoenix.LiveView.put_flash(:error, refusal.flash)
        |> Phoenix.LiveView.redirect(to: refusal.to)
        |> then(&{:halt, &1})
    end
  end

  @doc """
  Whether this user may exercise admin capability, and where to send them if
  not.

  Takes a user and the credential the session was established with, rather
  than a conn or a socket, because three entry points need the same answer in
  three different shapes.

  `login_method` is the second half of the policy and not a refinement of the
  first. Enrolment is a database fact: it says a passkey exists, never that
  one was used. Without this argument a phished password opens `/admin` on any
  admin who has enrolled, which is the single attack the spec's Problem
  section names. `:login_method` is written once by
  `PortalWeb.UserAuth.complete_login/3` and never rewritten; `:reauth_method`
  deliberately is not reused here, because `mark_reauth/2` fires on every
  step-up and a recovery-code re-auth would silently revoke admin mid-session.
  """
  @spec check(User.t() | nil, atom() | nil) :: {:ok, User.t()} | {:error, refusal()}
  def check(user, login_method \\ nil)

  def check(nil, _login_method) do
    {:error, %{to: ~p"/login", flash: "Sign in with an admin account."}}
  end

  def check(%User{} = user, login_method) do
    cond do
      # `admin?/1` restates the scope `Mfa.admin_satisfied?/1` also enforces
      # (`mfa.ex:45` answers true for a non-admin), so removing either alone is
      # behaviour-neutral and removing both is not. An authorization site
      # states its own scope rather than inheriting a collaborator's default;
      # it also keeps the gate right for a `%User{}` whose `is_admin` was not
      # selected. The scoping is pinned in `Portal.Accounts.MfaTest`.
      Portal.Accounts.admin?(user) and not Portal.Accounts.Mfa.admin_satisfied?(user) ->
        {:error,
         %{
           to: ~p"/settings/security",
           flash: "Admin access needs a passkey. Add one to continue."
         }}

      # Enrolled, but this session was not opened with the passkey. The
      # enrolled admin who signed in with a password is exactly the phished
      # case, so they get the same door as the unenrolled one, with the
      # message that matches what they have to do about it.
      Portal.Accounts.admin?(user) and login_method != :passkey ->
        {:error,
         %{
           to: ~p"/settings/security",
           flash: "Admin access needs a passkey sign-in. Sign in with your passkey to continue."
         }}

      Portal.Accounts.admin?(user) ->
        {:ok, user}

      true ->
        {:error, %{to: ~p"/request-scan", flash: "Admin access is required."}}
    end
  end

  defp load_user(user_id) do
    case Portal.Accounts.get_user(user_id) do
      {:ok, user} -> user
      _ -> nil
    end
  end
end
