defmodule Portal.Accounts do
  @moduledoc """
  Ash domain for identities that use the scan request portal.
  """

  use Ash.Domain

  resources do
    resource(Portal.Accounts.User)
    resource(Portal.Accounts.Passkey)
    resource(Portal.Accounts.TotpSecret)
    resource(Portal.Accounts.RecoveryCode)
  end

  @username_regex ~r/^[a-zA-Z0-9_][a-zA-Z0-9_.-]{2,39}$/

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

  The password is only ever returned, never stored or logged in clear.
  """
  @spec set_temporary_password(Portal.Accounts.User.t()) ::
          {:ok, Portal.Accounts.User.t(), String.t()} | {:error, term()}
  def set_temporary_password(%Portal.Accounts.User{} = user) do
    temp = temporary_password()

    with {:ok, updated} <-
           update_profile(user, %{
             password_hash: Argon2.hash_pwd_salt(temp),
             password_reset_required: true,
             password_set: true
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
  Replaces a user's password after verifying the current one with Argon2.
  """
  def change_password(%Portal.Accounts.User{} = user, current_password, new_password) do
    cond do
      not current_password?(user, current_password) ->
        {:error, :invalid_current_password}

      not valid_password?(new_password) ->
        {:error, :invalid_password}

      true ->
        update_profile(user, %{
          password_hash: Argon2.hash_pwd_salt(new_password),
          password_reset_required: false,
          password_set: true
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
