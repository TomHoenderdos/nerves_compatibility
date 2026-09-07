defmodule Portal.Accounts do
  @moduledoc """
  Ash domain for identities that use the scan request portal.
  """

  use Ash.Domain

  resources do
    resource(Portal.Accounts.User)
  end

  @username_regex ~r/^[a-zA-Z0-9_][a-zA-Z0-9_.-]{2,39}$/

  def register_user(username, password) do
    username = normalize_username(username)

    cond do
      not Regex.match?(@username_regex, username) ->
        {:error, :invalid_username}

      not valid_password?(password) ->
        {:error, :invalid_password}

      match?({:ok, %Portal.Accounts.User{}}, get_user_by_username(username)) ->
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

  def admin?(%Portal.Accounts.User{is_admin: true}), do: true

  def admin?(_user), do: false

  @doc """
  Changes the username of an existing user.

  The candidate is normalized like registration input and must match the shared
  username format. Keeping the current username is allowed; any other user
  already holding the name rejects the change.
  """
  def change_username(%Portal.Accounts.User{} = user, username) do
    username = normalize_username(username)

    cond do
      not Regex.match?(@username_regex, username) ->
        {:error, :invalid_username}

      username_taken_by_other?(user, username) ->
        {:error, :username_taken}

      true ->
        update_profile(user, %{username: username})
    end
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
        update_profile(user, %{password_hash: Argon2.hash_pwd_salt(new_password)})
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

  defp username_taken_by_other?(%Portal.Accounts.User{id: id}, username) do
    case get_user_by_username(username) do
      {:ok, %Portal.Accounts.User{id: existing_id}} -> existing_id != id
      _other -> false
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
