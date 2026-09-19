defmodule Portal.Accounts.Mfa do
  @moduledoc """
  Who must hold what, and what may authorise a change.

  Enrolment state is derived, never stored: an admin is satisfied when they
  hold at least one passkey, a community user when they hold a passkey or a
  confirmed TOTP. There is no flag to drift out of sync, and `set_admin` needs
  no special handling — a newly promoted admin simply fails the check on their
  next `/admin` request.
  """

  alias Portal.Accounts.{Passkeys, Totp, User}

  @reauth_window_seconds 600

  @type method :: :password | :passkey | :totp | :recovery_code

  @spec reauth_window_seconds() :: pos_integer()
  def reauth_window_seconds, do: @reauth_window_seconds

  @spec factors(User.t()) :: %{passkeys: non_neg_integer(), totp: boolean()}
  def factors(%User{} = user) do
    %{passkeys: Passkeys.count_for_user(user), totp: Totp.confirmed?(user)}
  end

  @spec enrolled?(User.t()) :: boolean()
  def enrolled?(%User{} = user) do
    case factors(user) do
      %{passkeys: 0, totp: false} -> false
      _ -> true
    end
  end

  @doc """
  Whether this account may enter `/admin`.

  TOTP does not satisfy an admin, and that is deliberate. An account is only
  as strong as its weakest factor: an admin holding both a passkey and TOTP
  can still be phished down to the TOTP, which would spend the phishing
  resistance that motivated passkeys in the first place.

  Non-admins are trivially satisfied — the requirement does not apply to them.
  """
  @spec admin_satisfied?(User.t()) :: boolean()
  def admin_satisfied?(%User{is_admin: false}), do: true
  def admin_satisfied?(%User{} = user), do: factors(user).passkeys > 0

  @doc """
  Whether a successful password check still owes a second step.

  A passkey is an alternative way to log in, not a second factor on top of a
  password, so holding one does not make the password flow two-phase.
  """
  @spec second_factor_required?(User.t()) :: boolean()
  def second_factor_required?(%User{} = user), do: factors(user).totp

  @doc """
  Which credentials may authorise adding or removing a factor.

  The password counts only while the account holds no factor at all — the
  bootstrap case, where it is the only credential that exists. Accepting it
  forever would make the admin passkey requirement decorative: a phished
  password would let an attacker enrol their own passkey and walk into
  `/admin`, which is the precise attack passkeys were chosen to stop.
  """
  @spec accepted_reauth_methods(User.t()) :: [method()]
  def accepted_reauth_methods(%User{} = user) do
    case factors(user) do
      %{passkeys: n} when n > 0 -> [:passkey, :recovery_code]
      %{totp: true} -> [:totp, :recovery_code]
      _ -> [:password]
    end
  end

  @doc """
  Whether `method`, proven at `at` (Unix seconds), still authorises a change.
  """
  @spec reauth_fresh?(User.t(), method() | nil, integer() | nil, integer()) :: boolean()
  def reauth_fresh?(user, method, at, now \\ System.system_time(:second))

  def reauth_fresh?(%User{}, nil, _at, _now), do: false
  def reauth_fresh?(%User{}, _method, nil, _now), do: false

  def reauth_fresh?(%User{} = user, method, at, now) when is_integer(at) and is_integer(now) do
    method in accepted_reauth_methods(user) and now >= at and
      now - at <= @reauth_window_seconds
  end
end
