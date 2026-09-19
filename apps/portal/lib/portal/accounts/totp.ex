defmodule Portal.Accounts.Totp do
  @moduledoc """
  TOTP as a second factor for password logins.

  Six digits is a million guesses, and an attacker who already holds the
  password will spend them, so verification counts failures and locks the
  secret after five. Replay inside a single 30-second window is blocked by
  handing `NimbleTOTP` the moment the last accepted code was used.

  TOTP never satisfies the admin passkey requirement. See
  `Portal.Accounts.Mfa`.

  ## Concurrency

  `confirm/3` and `verify/3` each do one read (to get the secret bytes needed
  for the HMAC check, which only Elixir can compute) followed by one write.
  Two concurrent calls can both read the same row before either writes, so
  every write that must not double-apply is a compare-and-swap: it carries an
  extra `WHERE` clause (via `Ash.Changeset.filter/2`) tied to the exact
  condition that made the write valid in the first place, and a write that
  loses the race matches zero rows instead of silently overwriting. Increments
  (`failed_attempts`) are computed as a database-side expression
  (`failed_attempts + 1`) instead of read-modify-written from the struct, so
  concurrent failures can't stomp each other.
  """

  require Ash.Expr
  require Ash.Query
  require Logger

  alias Ash.Error.Changes.StaleRecord
  alias Portal.Accounts.{TotpSecret, User}

  @max_failures 5
  @lockout_seconds 15 * 60
  @issuer "Nerves Compatibility Tracker"
  # Must match NimbleTOTP's own default `:period` (we never override it).
  @period_seconds 30

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

    {:ok, %{secret: secret, uri: otpauth_uri(user, secret)}}
  end

  @doc """
  The `otpauth://` URI for an enrolment still waiting on its first code.

  Lets a mistyped confirmation be re-rendered against the same QR code instead
  of costing the secret. A confirmed secret answers `:error`: there is no
  enrolment in flight, and re-displaying it would put a live factor's seed back
  on screen.
  """
  @spec enrolment_uri(User.t()) :: {:ok, String.t()} | :error
  def enrolment_uri(%User{} = user) do
    case get_secret(user) do
      {:ok, %TotpSecret{confirmed_at: nil, secret: secret}} -> {:ok, otpauth_uri(user, secret)}
      _ -> :error
    end
  end

  @doc """
  Turns an enrolled-but-unconfirmed secret into a real factor.

  Stamps `last_used_at` so the confirming code cannot immediately be replayed
  as a login. The write is guarded by `is_nil(confirmed_at)` so two concurrent
  confirmations of the same secret can't both succeed — the second finds the
  row no longer unconfirmed and loses.
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
      |> Ash.Changeset.filter(Ash.Expr.expr(is_nil(confirmed_at)))
      |> Ash.update(domain: Portal.Accounts)
      |> case do
        {:ok, _updated} -> :ok
        {:error, error} -> if stale?(error), do: {:error, :invalid_code}, else: raise(error)
      end
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
        claim_window(secret, user, now)
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

  defp otpauth_uri(%User{} = user, secret) do
    NimbleTOTP.otpauth_uri("#{@issuer}:#{user.username}", secret, issuer: @issuer)
  end

  defp confirmed_secret(user) do
    case get_secret(user) do
      {:ok, %TotpSecret{confirmed_at: nil}} -> {:error, :not_enrolled}
      {:ok, secret} -> {:ok, secret}
      :error -> {:error, :not_enrolled}
    end
  end

  # Known gap, recorded rather than fixed here: only the current 30-second step
  # is accepted. RFC 6238 §5.2 recommends also accepting one step backward, to
  # cover a phone clock a second fast and a user who finishes typing just after
  # a boundary; both get "That code did not match." today. Closing it means a
  # wider `claim_window/3` guard too, or the extra step reopens the replay
  # window the CAS above shuts — out of scope for the task that found it.
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

  # Claims the 30-second window `now` falls in as spent, but only if nobody
  # has already claimed it (`last_used_at` is still nil, or still in an
  # earlier window). This is the actual replay guard: `valid_code?/3` already
  # rejected the code once `last_used_at` reflects the current window, but
  # that check reads a struct fetched at the top of `verify/3` — two
  # concurrent callers both read the same stale row and both pass it. The
  # `WHERE` clause below is what turns "reject a used code" into "at most one
  # of two simultaneous winners", because a write that arrives second is
  # evaluated against the *other* caller's now-committed row, not the stale
  # one either of them started with.
  defp claim_window(secret, user, now) do
    boundary = step_start(now)

    secret
    |> Ash.Changeset.for_update(:record_success, %{
      last_used_at: now,
      failed_attempts: 0,
      locked_until: nil
    })
    |> Ash.Changeset.filter(Ash.Expr.expr(is_nil(last_used_at) or last_used_at < ^boundary))
    |> Ash.update(domain: Portal.Accounts)
    |> case do
      {:ok, _updated} ->
        :ok

      {:error, error} ->
        if stale?(error), do: record_failure(secret, user, now), else: raise(error)
    end
  end

  defp step_start(now) do
    unix = DateTime.to_unix(now)
    DateTime.from_unix!(div(unix, @period_seconds) * @period_seconds)
  end

  # `failed_attempts + 1` is a database-side expression, not a value computed
  # from `secret.failed_attempts` in this process — two concurrent failures
  # each issue their own `SET failed_attempts = failed_attempts + 1`, and
  # Postgres serialises the two `UPDATE`s on the row so neither's increment is
  # lost to the other's stale read.
  defp record_failure(secret, user, now) do
    updated =
      secret
      |> Ash.Changeset.for_update(:record_failure, %{})
      |> Ash.Changeset.atomic_update(:failed_attempts, Ash.Expr.expr(failed_attempts + 1))
      |> Ash.update!(domain: Portal.Accounts)

    if updated.failed_attempts >= @max_failures do
      lock(updated, user, now)
    else
      {:error, :invalid_code}
    end
  end

  # Second, separately-guarded write: only locks if the row is still at or
  # above the threshold at write time. If a concurrent success reset the
  # counter, or a concurrent failure already locked it, this write matches
  # zero rows and we fall back to reporting this attempt as merely invalid —
  # the account either isn't over threshold anymore, or is already locked by
  # the other writer.
  defp lock(secret, user, now) do
    until = DateTime.add(now, @lockout_seconds, :second)

    secret
    |> Ash.Changeset.for_update(:record_failure, %{failed_attempts: 0, locked_until: until})
    |> Ash.Changeset.filter(Ash.Expr.expr(failed_attempts >= ^@max_failures))
    |> Ash.update(domain: Portal.Accounts)
    |> case do
      {:ok, _updated} ->
        Logger.warning(
          "TOTP locked for user #{user.username} until #{DateTime.to_iso8601(until)}"
        )

        {:error, {:locked, until}}

      {:error, error} ->
        if stale?(error), do: {:error, :invalid_code}, else: raise(error)
    end
  end

  # `Ash.update/2` wraps a lost compare-and-swap as `%Ash.Error.Invalid{errors:
  # [%Ash.Error.Changes.StaleRecord{} | _]}`, not a bare `StaleRecord` — this
  # unwraps it so callers can tell "the row didn't match our WHERE clause"
  # (expected, means we lost the race) apart from any other write failure
  # (unexpected, should surface loudly).
  defp stale?(%Ash.Error.Invalid{errors: errors}) do
    Enum.any?(errors, &match?(%StaleRecord{}, &1))
  end

  defp stale?(_error), do: false
end
