defmodule Portal.Accounts.Totp do
  @moduledoc """
  TOTP as a second factor for password logins.

  Six digits is a million guesses, and an attacker who already holds the
  password will spend them, so verification counts failures and locks the
  secret after five. Replay inside a single 30-second window is blocked by
  handing `NimbleTOTP` the moment the last accepted code was used.

  TOTP never satisfies the admin passkey requirement. See
  `Portal.Accounts.Mfa`.
  """

  require Ash.Query
  require Logger

  alias Portal.Accounts.{TotpSecret, User}

  @max_failures 5
  @lockout_seconds 15 * 60
  @issuer "Nerves Compatibility Tracker"

  @doc """
  Mints a new secret for `user`, replacing any existing one, and returns it
  with the `otpauth://` URI to render as a QR code.

  The secret is unconfirmed until `confirm/3` proves one working code.
  """
  @spec start_enrolment(User.t()) :: {:ok, %{secret: binary(), uri: String.t()}}
  def start_enrolment(%User{id: user_id} = user) do
    :ok = disable(user)

    secret = NimbleTOTP.secret()

    TotpSecret
    |> Ash.Changeset.for_create(:create, %{secret: secret, user_id: user_id})
    |> Ash.create!(domain: Portal.Accounts)

    uri = NimbleTOTP.otpauth_uri("#{@issuer}:#{user.username}", secret, issuer: @issuer)

    {:ok, %{secret: secret, uri: uri}}
  end

  @doc """
  Turns an enrolled-but-unconfirmed secret into a real factor.

  Stamps `last_used_at` so the confirming code cannot immediately be replayed
  as a login.
  """
  @spec confirm(User.t(), String.t(), DateTime.t()) ::
          :ok | {:error, :not_enrolled | :invalid_code}
  def confirm(%User{} = user, code, now \\ DateTime.utc_now()) do
    with {:ok, secret} <- get_secret(user),
         true <- valid_code?(secret, code, now) do
      secret
      |> Ash.Changeset.for_update(:confirm, %{
        confirmed_at: now,
        last_used_at: now,
        failed_attempts: 0
      })
      |> Ash.update!(domain: Portal.Accounts)

      :ok
    else
      :error -> {:error, :not_enrolled}
      false -> {:error, :invalid_code}
    end
  end

  @doc """
  Checks a code against the user's confirmed secret.
  """
  @spec verify(User.t(), String.t(), DateTime.t()) ::
          :ok | {:error, :not_enrolled | :invalid_code | {:locked, DateTime.t()}}
  def verify(%User{} = user, code, now \\ DateTime.utc_now()) do
    with {:ok, secret} <- confirmed_secret(user),
         :ok <- check_lock(secret, now) do
      if valid_code?(secret, code, now) do
        record_success(secret, now)
      else
        record_failure(secret, user, now)
      end
    end
  end

  @spec confirmed?(User.t()) :: boolean()
  def confirmed?(%User{} = user), do: match?({:ok, _}, confirmed_secret(user))

  @spec get_secret(User.t()) :: {:ok, TotpSecret.t()} | :error
  def get_secret(%User{id: user_id}) do
    TotpSecret
    |> Ash.Query.filter(user_id == ^user_id)
    |> Ash.read(domain: Portal.Accounts)
    |> case do
      {:ok, [secret]} -> {:ok, secret}
      _ -> :error
    end
  end

  @spec disable(User.t()) :: :ok
  def disable(%User{} = user) do
    case get_secret(user) do
      {:ok, secret} -> Ash.destroy!(secret, domain: Portal.Accounts)
      :error -> :ok
    end

    :ok
  end

  defp confirmed_secret(user) do
    case get_secret(user) do
      {:ok, %TotpSecret{confirmed_at: nil}} -> {:error, :not_enrolled}
      {:ok, secret} -> {:ok, secret}
      :error -> {:error, :not_enrolled}
    end
  end

  defp valid_code?(%TotpSecret{} = secret, code, now) when is_binary(code) do
    NimbleTOTP.valid?(secret.secret, String.trim(code),
      time: now,
      since: secret.last_used_at
    )
  end

  defp valid_code?(_secret, _code, _now), do: false

  defp check_lock(%TotpSecret{locked_until: nil}, _now), do: :ok

  defp check_lock(%TotpSecret{locked_until: until}, now) do
    if DateTime.compare(now, until) == :lt, do: {:error, {:locked, until}}, else: :ok
  end

  defp record_success(secret, now) do
    secret
    |> Ash.Changeset.for_update(:record_success, %{
      last_used_at: now,
      failed_attempts: 0,
      locked_until: nil
    })
    |> Ash.update!(domain: Portal.Accounts)

    :ok
  end

  defp record_failure(secret, user, now) do
    attempts = secret.failed_attempts + 1

    if attempts >= @max_failures do
      until = DateTime.add(now, @lockout_seconds, :second)

      secret
      |> Ash.Changeset.for_update(:record_failure, %{failed_attempts: 0, locked_until: until})
      |> Ash.update!(domain: Portal.Accounts)

      Logger.warning("TOTP locked for user #{user.username} until #{DateTime.to_iso8601(until)}")

      {:error, {:locked, until}}
    else
      secret
      |> Ash.Changeset.for_update(:record_failure, %{failed_attempts: attempts})
      |> Ash.update!(domain: Portal.Accounts)

      {:error, :invalid_code}
    end
  end
end
