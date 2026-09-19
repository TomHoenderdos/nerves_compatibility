defmodule PortalWeb.PasskeyController do
  @moduledoc """
  JSON endpoints for signing in with a passkey and no password.

  Both actions speak JSON because the browser's WebAuthn API is asynchronous
  and deals in `ArrayBuffer`s; every binary crosses the wire base64url-encoded.
  """

  use PortalWeb, :controller

  require Logger

  alias Portal.Accounts.WebAuthn
  alias PortalWeb.{UserAuth, WebAuthnSession}

  @session_key :passkey_login_challenge

  def login_challenge(conn, _params) do
    {challenge, payload} = WebAuthn.authentication_challenge()

    conn
    |> WebAuthnSession.put(@session_key, challenge)
    |> json(payload)
  end

  def login_verify(conn, params) do
    case WebAuthnSession.take(conn, @session_key) do
      {:ok, challenge, conn} -> verify(conn, params, challenge)
      {:error, conn} -> deny(conn, :no_challenge)
    end
  end

  defp verify(conn, params, challenge) do
    case WebAuthn.authenticate(params, challenge) do
      {:ok, %{user: user}} ->
        conn
        |> UserAuth.complete_login(user, :passkey)
        |> put_flash(:info, "Signed in.")
        |> json(%{redirect_to: UserAuth.landing_path(user)})

      {:error, reason} ->
        deny(conn, reason)
    end
  end

  defp deny(conn, reason) do
    Logger.info("Passkey sign-in refused: #{inspect(reason)}")

    # One message for every failure. Distinguishing "no such credential" from
    # "bad signature" would tell an attacker which credential ids are real.
    conn
    |> put_status(:unauthorized)
    |> json(%{error: "That passkey could not be verified. Try again, or use your password."})
  end
end
