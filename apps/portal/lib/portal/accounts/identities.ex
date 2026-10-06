defmodule Portal.Accounts.Identities do
  @moduledoc """
  Which portal account a Hex.pm or GitHub identity belongs to.

  Every rule here rests on one: an identity is matched only through a link
  stored after the provider vouched for it. A name that happens to equal a
  local username proves nothing -- a Hex user called `tom` is not the local
  admin `tom` -- so names are only ever suggestions for new accounts.
  """

  require Ash.Query
  require Logger

  alias Portal.Accounts.{Identity, Passkeys, User}

  @spec find_user(Identity.t()) :: {:ok, User.t() | nil}
  def find_user(%Identity{provider: :hex, uid: uid}) do
    User
    |> Ash.Query.filter(hex_username == ^uid)
    |> Ash.read_one(domain: Portal.Accounts)
  end

  def find_user(%Identity{provider: :github, uid: uid}) do
    User
    |> Ash.Query.filter(github_id == ^uid)
    |> Ash.read_one(domain: Portal.Accounts)
  end

  @spec sign_in(Identity.t()) :: {:ok, User.t()} | {:error, term()}
  def sign_in(%Identity{} = identity) do
    case find_user(identity) do
      {:ok, nil} -> create_if_free(identity)
      {:ok, %User{} = user} -> record_login(user, identity)
      {:error, _} = error -> error
    end
  end

  @spec create_with_username(Identity.t(), String.t()) ::
          {:ok, User.t()}
          | {:error, :invalid_username | :username_taken | :identity_taken | term()}
  def create_with_username(%Identity{} = identity, username) do
    username = username |> to_string() |> String.trim() |> String.downcase()

    cond do
      not Portal.Accounts.valid_username?(username) ->
        {:error, :invalid_username}

      match?({:ok, %User{}}, find_user(identity)) ->
        {:error, :identity_taken}

      Portal.Accounts.username_taken?(username) ->
        {:error, :username_taken}

      true ->
        create(identity, username)
    end
  end

  @spec link(User.t(), Identity.t()) ::
          {:ok, User.t()} | {:error, :linked_elsewhere | :provider_already_linked | term()}
  def link(%User{} = user, %Identity{} = identity) do
    cond do
      matches?(user, identity) ->
        record_login(user, identity)

      linked?(user, identity.provider) ->
        {:error, :provider_already_linked}

      match?({:ok, %User{}}, find_user(identity)) ->
        {:error, :linked_elsewhere}

      true ->
        with {:ok, user} <- update_links(user, link_attrs(identity)) do
          Logger.info("Linked #{identity.provider} #{inspect(identity.uid)} to user #{user.id}")
          record_login(user, identity)
        end
    end
  end

  @spec unlink(User.t(), Identity.provider()) ::
          {:ok, User.t()} | {:error, :not_linked | :last_way_in | term()}
  def unlink(%User{} = user, provider) when provider in [:hex, :github] do
    cond do
      not linked?(user, provider) ->
        {:error, :not_linked}

      ways_in(user) -- [provider] == [] ->
        {:error, :last_way_in}

      true ->
        with {:ok, user} <- update_links(user, unlink_attrs(provider)) do
          Logger.info("Unlinked #{provider} from user #{user.id}")
          {:ok, user}
        end
    end
  end

  @spec matches?(User.t(), Identity.t()) :: boolean()
  def matches?(%User{hex_username: linked}, %Identity{provider: :hex, uid: uid}),
    do: is_binary(linked) and linked == uid

  def matches?(%User{github_id: linked}, %Identity{provider: :github, uid: uid}),
    do: is_integer(linked) and linked == uid

  @spec for_scan_request(Identity.t(), User.t() | nil) :: {:ok, User.t() | nil} | {:error, term()}
  def for_scan_request(%Identity{} = _identity, %User{} = current_user) do
    # A scan request never links. Linking is an account change and belongs
    # behind step-up in Settings; without this, a stolen session cookie could
    # turn a provider's say-so into a permanent login for this account just by
    # running a scan. The identity only verifies *this* request -- it stays
    # the signed-in user's regardless of where (or whether) the identity is
    # linked.
    {:ok, current_user}
  end

  def for_scan_request(%Identity{} = identity, nil) do
    case sign_in(identity) do
      {:ok, user} -> {:ok, user}
      {:error, :choose_username} -> {:ok, nil}
      {:error, _} = error -> error
    end
  end

  @spec ways_in(User.t()) :: [:password | :hex | :github | :passkey]
  def ways_in(%User{} = user) do
    [
      user.password_set && :password,
      linked?(user, :hex) && :hex,
      linked?(user, :github) && :github,
      Passkeys.count_for_user(user) > 0 && :passkey
    ]
    |> Enum.filter(& &1)
  end

  @spec linked?(User.t(), Identity.provider()) :: boolean()
  def linked?(%User{hex_username: name}, :hex), do: is_binary(name)
  def linked?(%User{github_id: id}, :github), do: is_integer(id)

  defp create_if_free(identity) do
    username = String.downcase(identity.username)

    if Portal.Accounts.valid_username?(username) and
         not Portal.Accounts.username_taken?(username) do
      create(identity, username)
    else
      {:error, :choose_username}
    end
  end

  defp create(identity, username) do
    attrs =
      identity
      |> link_attrs()
      |> Map.merge(login_attrs(identity))
      |> Map.merge(%{
        username: username,
        password_hash: random_password_hash(),
        password_set: false
      })

    with {:ok, user} <-
           User |> Ash.Changeset.for_create(:create, attrs) |> Ash.create(domain: Portal.Accounts) do
      Logger.info(
        "Created user #{user.id} (#{username}) from #{identity.provider} #{inspect(identity.uid)}"
      )

      {:ok, user}
    end
  end

  defp record_login(user, %Identity{provider: :hex} = identity) do
    user
    |> Ash.Changeset.for_update(:record_hex_login, login_attrs(identity))
    |> Ash.update(domain: Portal.Accounts)
  end

  defp record_login(user, %Identity{provider: :github} = identity) do
    user
    |> Ash.Changeset.for_update(:record_github_login, login_attrs(identity))
    |> Ash.update(domain: Portal.Accounts)
  end

  defp login_attrs(%Identity{provider: :hex} = identity) do
    %{hex_profile: Jason.encode!(identity.profile), last_hex_login_at: now()}
  end

  defp login_attrs(%Identity{provider: :github} = identity) do
    %{
      github_username: identity.username,
      github_profile: Jason.encode!(identity.profile),
      last_github_login_at: now()
    }
  end

  defp link_attrs(%Identity{provider: :hex, uid: uid}), do: %{hex_username: uid}

  defp link_attrs(%Identity{provider: :github, uid: uid, username: login}),
    do: %{github_id: uid, github_username: login}

  defp unlink_attrs(:hex), do: %{hex_username: nil, hex_profile: "{}"}
  defp unlink_attrs(:github), do: %{github_id: nil, github_username: nil, github_profile: "{}"}

  defp update_links(user, attrs) do
    user |> Ash.Changeset.for_update(:set_links, attrs) |> Ash.update(domain: Portal.Accounts)
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp random_password_hash do
    32
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
    |> Argon2.hash_pwd_salt()
  end
end
