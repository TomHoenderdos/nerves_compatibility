defmodule Portal.Accounts do
  @moduledoc """
  Ash domain for identities that use the scan request portal.
  """

  use Ash.Domain

  require Logger

  resources do
    resource(Portal.Accounts.User)
    resource(Portal.Accounts.Passkey)
    resource(Portal.Accounts.TotpSecret)
    resource(Portal.Accounts.RecoveryCode)
  end

  @username_regex ~r/^[a-zA-Z0-9_][a-zA-Z0-9_.-]{2,39}$/

  @doc """
  The id every live socket of `user_id`'s sessions connects under.

  `PortalWeb.UserAuth.complete_login/3` stores it in the session as
  `:live_socket_id`, where `Phoenix.LiveView.Socket.id/1` reads it on every
  connect. It names the user, not the session: there is no server-side
  session to name, since the session store is the signed cookie.
  """
  @spec live_socket_id(String.t()) :: String.t()
  def live_socket_id(user_id) when is_binary(user_id), do: "users_socket:#{user_id}"

  @doc """
  Closes every live socket `user_id` has open, in every browser.

  A LiveView authenticates once, when it mounts, and its later work --
  Cinder's paging and filtering, PubSub-driven refreshes -- runs on the actor
  it mounted with. The client reconnects at once, which mounts again and so
  re-runs every `on_mount` hook against the database as it is now: an admin
  page refuses a demoted admin, and a signed-out browser, whose cookie no
  longer holds the CSRF token the page was rendered with, is told to reload.
  Called wherever a user's access shrinks: sign-out, admin revoked, password
  reset, passkey removed.

  Sessions signed in before live socket ids existed connect under no id, so
  this does not reach them; they still meet every gate on their next mount.
  """
  @spec disconnect_live_sockets(String.t(), module()) :: :ok | {:error, term()}
  def disconnect_live_sockets(user_id, endpoint \\ PortalWeb.Endpoint) when is_binary(user_id) do
    endpoint.broadcast(live_socket_id(user_id), "disconnect", %{})
  rescue
    # Best-effort: the disconnect only hurries along what the next mount
    # would refuse anyway, so it must never break the change it follows.
    # Without a running endpoint -- `bin/portal eval`, `mix run --no-start`,
    # where the break-glass `Recovery.clear_factors!/1` deletes passkeys --
    # `broadcast/3` raises `ArgumentError` reading the endpoint's config, and
    # there are no live sockets to disconnect.
    error in ArgumentError ->
      Logger.debug("Live socket disconnect skipped: #{Exception.message(error)}")
      :ok
  end

  @doc """
  The user a session belongs to, or `nil` if it belongs to nobody any more.

  The one check every request and every LiveView mount makes before trusting
  a session's `user_id`: `PortalWeb.UserAuth` for the signed-in pages and
  the public LiveViews, `PortalWeb.Plugs.RequireAdmin` for `/admin`.
  `started_at` is the session's `:session_started_at`, in microseconds; a
  session older than the user's `sessions_valid_after` is signed out, as is
  one for an account that no longer exists.
  """
  @spec session_user(term(), term()) :: Portal.Accounts.User.t() | nil
  def session_user(user_id, started_at) do
    case get_user(user_id) do
      {:ok, %Portal.Accounts.User{} = user} ->
        if session_current?(user, started_at), do: user, else: nil

      _missing ->
        nil
    end
  end

  @doc """
  Whether a session that started at `started_at` (microseconds since the
  epoch) is still valid for `user`.

  A session with no start time predates the stamp, and counts as started at
  the epoch: valid while the user has never revoked their sessions, refused
  from the first revocation on. That is what reaches the sessions signed in
  before this check existed, which carry no live socket id either.
  """
  @spec session_current?(Portal.Accounts.User.t(), term()) :: boolean()
  def session_current?(%Portal.Accounts.User{sessions_valid_after: nil}, _started_at), do: true

  def session_current?(
        %Portal.Accounts.User{sessions_valid_after: %DateTime{} = cutoff},
        started_at
      ) do
    started = if is_integer(started_at), do: started_at, else: 0
    started >= DateTime.to_unix(cutoff, :microsecond)
  end

  @doc """
  Signs `user` out of every session they have, in every browser, from the
  next request or LiveView mount on.

  A caller acting from one of those sessions that should survive re-stamps it
  afterwards (`PortalWeb.UserAuth.restamp_session/2`). Pair it with
  `disconnect_live_sockets/1`, which makes open pages notice at once; this is
  what makes it stick when they reconnect, and reaches sessions the
  disconnect cannot.
  """
  @spec revoke_sessions(Portal.Accounts.User.t()) ::
          {:ok, Portal.Accounts.User.t()} | {:error, term()}
  def revoke_sessions(%Portal.Accounts.User{} = user),
    do: update_profile(user, %{sessions_valid_after: DateTime.utc_now()})

  def valid_username?(username) when is_binary(username),
    do: Regex.match?(@username_regex, username)

  def valid_username?(_), do: false

  def register_user(username, password) do
    username = normalize_username(username)

    cond do
      not valid_username?(username) ->
        {:error, :invalid_username}

      not valid_password?(password) ->
        {:error, :invalid_password}

      username_taken?(username) ->
        {:error, :username_taken}

      true ->
        Portal.Accounts.User
        |> Ash.Changeset.for_create(:create, %{
          username: username,
          password_hash: Argon2.hash_pwd_salt(password)
        })
        |> Ash.create(domain: __MODULE__)
    end
  end

  def authenticate_user(username, password) do
    username = normalize_username(username)

    with {:ok, %Portal.Accounts.User{} = user} <- get_user_by_username(username),
         true <- Argon2.verify_pass(password, user.password_hash) do
      {:ok, user}
    else
      {:ok, nil} ->
        Argon2.no_user_verify()
        {:error, :invalid_credentials}

      false ->
        {:error, :invalid_credentials}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def get_user(id) when is_binary(id) do
    with {:ok, users} <- Ash.read(Portal.Accounts.User, domain: __MODULE__) do
      {:ok, Enum.find(users, &(&1.id == id))}
    end
  end

  def get_user(_), do: {:ok, nil}

  def get_user_by_username(username) do
    username = normalize_username(username)

    with {:ok, users} <- Ash.read(Portal.Accounts.User, domain: __MODULE__) do
      {:ok, Enum.find(users, &(&1.username == username))}
    end
  end

  @doc """
  Whether any account already holds `username`, case-insensitively.

  Exists alongside `get_user_by_username/1` (exact match, used to log
  someone in or resolve an admin by name) because the two questions are not
  the same: the old provider flows stored a login verbatim ("JaneDoe"),
  so "is this name free for a new account or a rename" has to see that
  legacy row even though a plain lookup for "janedoe" must not silently
  return it -- `get_user_by_username/1` returning the wrong account under the
  unique index's nose, rather than this function returning a boolean, is what
  could grant admin to or sign in as the wrong person.
  """
  @spec username_taken?(String.t()) :: boolean()
  def username_taken?(username) do
    username = normalize_username(username)

    case Ash.read(Portal.Accounts.User, domain: __MODULE__) do
      {:ok, users} -> Enum.any?(users, &(String.downcase(&1.username) == username))
      {:error, _} -> false
    end
  end

  def admin?(%Portal.Accounts.User{is_admin: true}), do: true

  def admin?(_user), do: false

  @doc """
  Changes the username of an existing user.

  The candidate is normalized like registration input and must match the shared
  username format. Keeping the current username, or changing only its case, is
  allowed; any other user holding the name in any case rejects the change, so
  a rename cannot create a case-twin of a legacy mixed-case name.
  """
  def change_username(%Portal.Accounts.User{} = user, username) do
    username = normalize_username(username)

    cond do
      not valid_username?(username) ->
        {:error, :invalid_username}

      username_taken_by_other?(user, username) ->
        {:error, :username_taken}

      true ->
        update_profile(user, %{username: username})
    end
  end

  @doc """
  Replaces `user`'s password with a random one and returns it, marking the
  account so the next login asks for a new password. For an admin handing a
  locked-out user a way back in: there is no email to send a reset link to.

  The password is only ever returned, never stored or logged in clear. Every
  session on the account is signed out (`revoke_sessions/1`).
  """
  @spec set_temporary_password(Portal.Accounts.User.t()) ::
          {:ok, Portal.Accounts.User.t(), String.t()} | {:error, term()}
  def set_temporary_password(%Portal.Accounts.User{} = user) do
    temp = temporary_password()

    with {:ok, updated} <-
           update_profile(user, %{
             password_hash: Argon2.hash_pwd_salt(temp),
             password_reset_required: true,
             password_set: true,
             # In the same write as the password: whoever holds a session
             # on this account is why it is being reset.
             sessions_valid_after: DateTime.utc_now()
           }) do
      {:ok, updated, temp}
    end
  end

  # Four groups of five base32 characters: 100 bits, easy to read aloud or
  # paste, and long enough to pass valid_password?/1.
  defp temporary_password do
    20
    |> :crypto.strong_rand_bytes()
    |> Base.encode32(case: :lower, padding: false)
    |> binary_part(0, 20)
    |> String.graphemes()
    |> Enum.chunk_every(5)
    |> Enum.map_join("-", &Enum.join/1)
  end

  @doc """
  Replaces a user's password after verifying the current one with Argon2,
  and signs every session on the account out (`revoke_sessions/1`).
  """
  def change_password(%Portal.Accounts.User{} = user, current_password, new_password) do
    cond do
      not current_password?(user, current_password) ->
        {:error, :invalid_current_password}

      not valid_password?(new_password) ->
        {:error, :invalid_password}

      true ->
        # Every other session ends with the old password, in the same write.
        # The caller keeps its own (`PortalWeb.UserAuth.restamp_session/2`).
        update_profile(user, %{
          password_hash: Argon2.hash_pwd_salt(new_password),
          password_reset_required: false,
          password_set: true,
          sessions_valid_after: DateTime.utc_now()
        })
    end
  end

  @doc """
  Gives a password to an account that has none anyone knows. The caller
  enforces the step-up check; there is no current password to ask for.

  An account that already has a password is refused here as well as in the
  controller: this path skips the current-password check, so it must never
  replace a password someone knows.
  """
  @spec set_password(Portal.Accounts.User.t(), String.t()) ::
          {:ok, Portal.Accounts.User.t()}
          | {:error, :password_already_set | :invalid_password}
          | {:error, term()}
  def set_password(%Portal.Accounts.User{password_set: true}, _new_password),
    do: {:error, :password_already_set}

  def set_password(%Portal.Accounts.User{} = user, new_password) do
    if valid_password?(new_password) do
      update_profile(user, %{
        password_hash: Argon2.hash_pwd_salt(new_password),
        password_set: true,
        password_reset_required: false
      })
    else
      {:error, :invalid_password}
    end
  end

  def seed_admin_user(username, password \\ nil) do
    username = normalize_username(username)

    with :ok <- validate_seed_username(username) do
      case get_user_by_username(username) do
        {:ok, %Portal.Accounts.User{} = user} ->
          set_admin(user, true)

        {:ok, nil} when is_binary(password) ->
          create_seed_admin(username, password)

        {:ok, nil} ->
          {:error, :password_required}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp normalize_username(username) when is_binary(username) do
    username
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_username(_), do: ""

  defp valid_password?(password) when is_binary(password), do: String.length(password) >= 12
  defp valid_password?(_), do: false

  defp validate_seed_username(username) do
    if Regex.match?(@username_regex, username) do
      :ok
    else
      {:error, :invalid_username}
    end
  end

  defp create_seed_admin(username, password) do
    if valid_password?(password) do
      Portal.Accounts.User
      |> Ash.Changeset.for_create(:create, %{
        username: username,
        password_hash: Argon2.hash_pwd_salt(password),
        is_admin: true
      })
      |> Ash.create(domain: __MODULE__)
    else
      {:error, :invalid_password}
    end
  end

  # Case-insensitive for the same reason as `username_taken?/1`, but the
  # user's own row does not count against them.
  defp username_taken_by_other?(%Portal.Accounts.User{id: id}, username) do
    case Ash.read(Portal.Accounts.User, domain: __MODULE__) do
      {:ok, users} ->
        Enum.any?(users, &(&1.id != id and String.downcase(&1.username) == username))

      {:error, _} ->
        false
    end
  end

  defp current_password?(%Portal.Accounts.User{} = user, password) when is_binary(password) do
    Argon2.verify_pass(password, user.password_hash)
  end

  defp current_password?(_user, _password), do: false

  defp update_profile(user, params) do
    user
    |> Ash.Changeset.for_update(:update_profile, params)
    |> Ash.update(domain: __MODULE__)
  end

  defp set_admin(user, is_admin) do
    user
    |> Ash.Changeset.for_update(:set_admin, %{is_admin: is_admin})
    |> Ash.update(domain: __MODULE__)
  end
end
