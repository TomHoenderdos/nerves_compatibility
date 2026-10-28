defmodule Portal.Accounts.RecoveryCodes do
  @moduledoc """
  Single-use recovery codes: the way back in when the passkey is gone.

  Each code is `:crypto.strong_rand_bytes(10)` — exactly 80 bits — Base32
  encoded (RFC 4648) to 16 characters with no padding, shown lowercase in four
  groups. The Base32 alphabet is `A-Z` plus `2-7`, which has no `0`/`O` or
  `1`/`I`/`l` pairs, so there is nothing to misread off a printed sheet.

  Hashing is SHA-256, deliberately not Argon2: 80 bits of CSPRNG output has
  nothing to brute-force, and Argon2 would cost up to ten ~100 ms
  verifications per login attempt. The fast hash is only safe because the
  codes are long. Do not shorten them without switching to Argon2.
  """

  require Ash.Query

  alias Portal.Accounts.{RecoveryCode, User}

  @count 10
  @entropy_bytes 10
  @low_water 2

  @doc """
  Issues a fresh set of ten codes, discarding any previous set.

  The plaintext is returned once and never stored. The caller must show it to
  the user immediately; there is no second chance to read it.
  """
  @spec generate(User.t()) :: {:ok, [String.t()]}
  def generate(%User{} = user) do
    {:ok, codes, _user} = regenerate(user)
    {:ok, codes}
  end

  @doc """
  `generate/1`, returning the user as well.

  Discarding a set that still holds unused codes takes a way in away, and a
  printed sheet may be why it is being replaced, so every session on the
  account ends with it (`Portal.Accounts.revoke_sessions_with/2`); the user
  comes back revoked for the caller to re-stamp its own session. A first
  set, or one already spent, takes nothing away and revokes nothing.
  """
  @spec regenerate(User.t()) :: {:ok, [String.t()], User.t()}
  def regenerate(%User{} = user) do
    codes = Enum.map(1..@count, fn _ -> new_code() end)

    {:ok, user} =
      if remaining(user) > 0 do
        Portal.Accounts.revoke_sessions_with(user, fn -> replace(user, codes) end)
      else
        :ok = replace(user, codes)
        {:ok, user}
      end

    {:ok, Enum.map(codes, &format/1), user}
  end

  defp replace(%User{id: user_id} = user, codes) do
    user |> all_for_user() |> Enum.each(&Ash.destroy!(&1, domain: Portal.Accounts))

    for code <- codes do
      RecoveryCode
      |> Ash.Changeset.for_create(:create, %{code_hash: hash(code), user_id: user_id})
      |> Ash.create!(domain: Portal.Accounts)
    end

    :ok
  end

  @doc """
  Spends a code. Accepts it in any case, with or without the display dashes.

  The match-and-stamp happens as a single atomic `UPDATE ... WHERE used_at IS
  NULL` (via `Ash.bulk_update/4` with `strategy: :atomic`), not a read
  followed by a separate write. Two concurrent callers racing on the same
  code therefore cannot both win: Postgres serialises the two `UPDATE`s on
  the row, and whichever commits second re-evaluates the `WHERE` clause
  against the now-committed row and finds `used_at` no longer `NULL`, so it
  updates zero rows instead of raising or double-spending the code. The same
  query also can't raise if a concurrent `generate/1` destroys the row
  first — zero rows matched is just another `{:error, :invalid_code}`.
  """
  @spec consume(User.t(), String.t()) :: :ok | {:error, :invalid_code}
  def consume(%User{id: user_id}, input) when is_binary(input) do
    hashed = input |> normalize() |> hash()

    RecoveryCode
    |> Ash.Query.filter(user_id == ^user_id and code_hash == ^hashed and is_nil(used_at))
    |> Ash.bulk_update(:consume, %{used_at: DateTime.utc_now()},
      domain: Portal.Accounts,
      strategy: :atomic,
      return_records?: true
    )
    |> case do
      %Ash.BulkResult{records: [_ | _]} -> :ok
      _ -> {:error, :invalid_code}
    end
  end

  def consume(%User{}, _input), do: {:error, :invalid_code}

  @spec remaining(User.t()) :: non_neg_integer()
  def remaining(%User{} = user) do
    user |> all_for_user() |> Enum.count(&is_nil(&1.used_at))
  end

  @doc "True once the user is down to the last couple of codes."
  @spec low?(User.t()) :: boolean()
  def low?(%User{} = user), do: remaining(user) <= @low_water

  @doc "Strips the display dashes and surrounding whitespace, and downcases."
  @spec normalize(String.t()) :: String.t()
  def normalize(input) when is_binary(input) do
    input |> String.trim() |> String.replace("-", "") |> String.downcase()
  end

  @doc "Groups a bare 16-character code into four dash-separated blocks."
  @spec format(String.t()) :: String.t()
  def format(code) when is_binary(code) do
    code
    |> String.graphemes()
    |> Enum.chunk_every(4)
    |> Enum.map_join("-", &Enum.join/1)
  end

  defp new_code do
    @entropy_bytes
    |> :crypto.strong_rand_bytes()
    |> Base.encode32(padding: false)
    |> String.downcase()
  end

  defp hash(code) do
    :sha256 |> :crypto.hash(code) |> Base.encode16(case: :lower)
  end

  defp all_for_user(%User{id: user_id}) do
    RecoveryCode
    |> Ash.Query.filter(user_id == ^user_id)
    |> Ash.read!(domain: Portal.Accounts)
  end
end
