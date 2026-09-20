defmodule Portal.Accounts.Recovery do
  @moduledoc """
  Break-glass recovery, run from a remote console on the web host.

  Strips every second factor off one account and prints a fresh set of
  recovery codes. There is no web route and no API for this, deliberately:
  reaching the console already means holding root on the host, which already
  holds the database credentials in `/etc/ncc-portal/portal.env`, so this
  grants no access an attacker at that level does not already have.

  The expression to run, naming the locked-out account:

      Portal.Accounts.Recovery.clear_factors!("tom")

  Pass the username that holds `is_admin`, which is not always the one that
  looks like the operator's own name -- this project's admin is `tom` while a
  separate non-admin `tomhoenderdos` account also exists, and clearing factors
  on the wrong one restores no access at all. `ops/README.md` opens with the
  query that settles it.

  For the runnable command, including the environment sourcing this needs to
  reach the database, see `ops/README.md`.
  """

  require Logger

  alias Portal.Accounts
  alias Portal.Accounts.{Passkeys, RecoveryCodes, Totp, User}

  @doc """
  Removes all passkeys and any authenticator app from `username`, issues ten
  fresh recovery codes, and returns them.

  Raises if no such account exists. Every existing recovery code stops
  working.
  """
  @spec clear_factors!(String.t()) :: [String.t()]
  def clear_factors!(username) when is_binary(username) do
    user = fetch_user!(username)

    passkeys = Passkeys.list_for_user(user)
    Enum.each(passkeys, fn passkey -> :ok = Passkeys.delete(user, passkey.id) end)
    :ok = Totp.disable(user)
    {:ok, codes} = RecoveryCodes.generate(user)

    Logger.warning(
      "BREAK-GLASS: cleared #{length(passkeys)} passkeys and TOTP for #{username}, " <>
        "issued #{length(codes)} recovery codes"
    )

    IO.puts("""

    Factors cleared for #{username}.

    Recovery codes — each works once, this is the only time they are shown:

    #{Enum.map_join(codes, "\n", &("  " <> &1))}

    Sign in at /login with the password. Nothing will ask for a second factor:
    this account no longer has one. Then enrol a passkey at /settings/security.

    Keep these codes. They are not needed to sign in right now, but the moment
    a passkey exists they become an accepted re-authentication method -- the
    way back in if that passkey is lost too.

    Admin access stays closed until a passkey is registered.
    """)

    codes
  end

  defp fetch_user!(username) do
    case Accounts.get_user_by_username(username) do
      {:ok, %User{} = user} -> user
      _ -> raise "no account named #{inspect(username)}"
    end
  end
end
