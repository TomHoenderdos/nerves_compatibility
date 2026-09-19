defmodule Portal.Accounts.Passkeys do
  @moduledoc """
  Reads and writes for `Portal.Accounts.Passkey`.

  Every function that mutates takes the owning user and scopes by it, so a
  credential id from a request body can never reach another account's row.
  """

  require Ash.Query

  alias Portal.Accounts.{Passkey, User}

  @spec list_for_user(User.t()) :: [Passkey.t()]
  def list_for_user(%User{id: user_id}) do
    Passkey
    |> Ash.Query.filter(user_id == ^user_id)
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.read!(domain: Portal.Accounts)
  end

  @doc """
  How many passkeys `user` holds.

  Counted in Postgres rather than by `length(list_for_user(user))`, which
  loaded every column -- including the COSE `public_key` binaries -- only to
  throw them away. This runs on every `/admin` request through
  `PortalWeb.Plugs.RequireAdmin.check/2` and twice per `/settings/security`
  render, and the spec budgeted one indexed count for it.
  """
  @spec count_for_user(User.t()) :: non_neg_integer()
  def count_for_user(%User{id: user_id}) do
    Passkey
    |> Ash.Query.filter(user_id == ^user_id)
    |> Ash.count!(domain: Portal.Accounts)
  end

  @spec get_by_credential_id(binary()) :: {:ok, Passkey.t()} | :error
  def get_by_credential_id(credential_id) when is_binary(credential_id) do
    Passkey
    |> Ash.Query.filter(credential_id == ^credential_id)
    |> Ash.read(domain: Portal.Accounts)
    |> case do
      {:ok, [passkey]} -> {:ok, passkey}
      _ -> :error
    end
  end

  @spec create(User.t(), map()) :: {:ok, Passkey.t()} | {:error, term()}
  def create(%User{id: user_id}, attrs) do
    Passkey
    |> Ash.Changeset.for_create(:create, Map.put(attrs, :user_id, user_id))
    |> Ash.create(domain: Portal.Accounts)
  end

  @spec delete(User.t(), String.t()) :: :ok | {:error, :not_found}
  def delete(%User{} = user, id) do
    user
    |> list_for_user()
    |> Enum.find(&(&1.id == id))
    |> case do
      nil ->
        {:error, :not_found}

      passkey ->
        Ash.destroy!(passkey, domain: Portal.Accounts)
        :ok
    end
  end

  @spec record_use(Passkey.t(), non_neg_integer()) :: {:ok, Passkey.t()} | {:error, term()}
  def record_use(%Passkey{} = passkey, sign_count) do
    passkey
    |> Ash.Changeset.for_update(:record_use, %{
      sign_count: sign_count,
      last_used_at: DateTime.utc_now()
    })
    |> Ash.update(domain: Portal.Accounts)
  end

  @doc """
  The COSE key as `wax_` wants it. `[:safe]` because the bytes came back out of
  the database and a bare `binary_to_term/1` on stored input is a remote code
  execution primitive if that storage is ever tampered with.
  """
  @spec cose_key(Passkey.t()) :: map()
  def cose_key(%Passkey{public_key: bin}), do: :erlang.binary_to_term(bin, [:safe])
end
