defmodule PortalWeb.MfaController do
  @moduledoc """
  The second step of a password login.

  Accepts either a six-digit TOTP code or a recovery code. Which one was used
  is recorded as the re-auth method, because a recovery code and a TOTP code
  authorise different things later — see `Portal.Accounts.Mfa`.
  """

  use PortalWeb, :controller

  alias Portal.Accounts.{RecoveryCodes, Totp}
  alias PortalWeb.UserAuth

  def totp_challenge(conn, _params) do
    case UserAuth.pending_user(conn) do
      {:ok, _user} -> render_challenge(conn)
      :error -> restart(conn, "That sign-in attempt expired. Start again.")
    end
  end

  def totp_verify(conn, params) do
    code = params |> Map.get("code", "") |> to_string()

    case UserAuth.pending_user(conn) do
      {:ok, user} -> check(conn, user, code)
      :error -> restart(conn, "That sign-in attempt expired. Start again.")
    end
  end

  defp check(conn, user, code) do
    # Recovery codes are checked first so a locked-out TOTP counter can never
    # refuse a valid, unused recovery code -- a deliberate behaviour change,
    # not an oversight. Wrong guesses still fall through to `Totp.verify/3`
    # below, so the lockout still rate-limits brute-force attempts on both
    # credential types.
    case RecoveryCodes.consume(user, code) do
      :ok ->
        finish(conn, user, :recovery_code)

      {:error, :invalid_code} ->
        case Totp.verify(user, code) do
          :ok ->
            finish(conn, user, :totp)

          {:error, {:locked, _until}} ->
            restart(conn, "Too many wrong codes. Sign in with your password again in 15 minutes.")

          {:error, _} ->
            reject(conn)
        end
    end
  end

  defp finish(conn, user, method) do
    conn
    |> UserAuth.complete_login(user, method)
    |> maybe_warn_low_codes(user, method)
    |> put_flash(:info, "Signed in.")
    |> redirect(to: UserAuth.landing_path(user, method))
  end

  defp maybe_warn_low_codes(conn, user, :recovery_code) do
    if RecoveryCodes.low?(user) do
      put_flash(
        conn,
        :error,
        "#{RecoveryCodes.remaining(user)} recovery codes left. Generate a new set in Security settings."
      )
    else
      conn
    end
  end

  defp maybe_warn_low_codes(conn, _user, _method), do: conn

  defp reject(conn) do
    conn
    |> put_flash(:error, "That code did not match. Try again.")
    |> render_challenge()
  end

  defp restart(conn, message) do
    conn
    |> UserAuth.drop_pending()
    |> put_flash(:error, message)
    |> redirect(to: ~p"/login")
  end

  defp render_challenge(conn) do
    render(conn, :totp_challenge,
      page_title: "Two-factor authentication",
      current_user: nil
    )
  end
end
