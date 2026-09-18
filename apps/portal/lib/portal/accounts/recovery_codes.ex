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
  def generate(%User{id: user_id} = user) do
    user |> all_for_user() |> Enum.each(&Ash.destroy!(&1, domain: Portal.Accounts))

    codes = Enum.map(1..@count, fn _ -> new_code() end)

    for code <- codes do
      RecoveryCode
      |> Ash.Changeset.for_create(:create, %{code_hash: hash(code), user_id: user_id})
      |> Ash.create!(domain: Portal.Accounts)
    end

    {:ok, Enum.map(codes, &format/1)}
  end

  @doc """
  Spends a code. Accepts it in any case, with or without the display dashes.
  """
  @spec consume(User.t(), String.t()) :: :ok | {:error, :invalid_code}
  def consume(%User{} = user, input) when is_binary(input) do
    hashed = input |> normalize() |> hash()

    user
    |> all_for_user()
    |> Enum.find(fn code -> is_nil(code.used_at) and code.code_hash == hashed end)
    |> case do
      nil ->
        {:error, :invalid_code}

      code ->
        code
        |> Ash.Changeset.for_update(:consume, %{used_at: DateTime.utc_now()})
        |> Ash.update!(domain: Portal.Accounts)

        :ok
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
