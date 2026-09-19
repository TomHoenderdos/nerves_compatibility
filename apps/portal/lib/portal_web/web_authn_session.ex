defmodule PortalWeb.WebAuthnSession do
  @moduledoc """
  Holds a `Wax.Challenge` in the signed session between the two halves of a
  WebAuthn ceremony.

  The session rather than the database: a challenge is worthless to anyone who
  cannot also present the assertion, it expires in five minutes, and this way
  there is no table to prune. `take/2` always deletes, so a challenge is
  single-use whether or not it verified.
  """

  import Plug.Conn

  @ttl_seconds 300

  @spec put(Plug.Conn.t(), atom(), Wax.Challenge.t()) :: Plug.Conn.t()
  def put(conn, key, %Wax.Challenge{} = challenge) do
    put_session(conn, key, {challenge, System.system_time(:second)})
  end

  @spec take(Plug.Conn.t(), atom()) ::
          {:ok, Wax.Challenge.t(), Plug.Conn.t()} | {:error, Plug.Conn.t()}
  def take(conn, key) do
    value = get_session(conn, key)
    conn = delete_session(conn, key)

    case value do
      {%Wax.Challenge{} = challenge, at} when is_integer(at) ->
        if System.system_time(:second) - at <= @ttl_seconds do
          {:ok, challenge, conn}
        else
          {:error, conn}
        end

      _ ->
        {:error, conn}
    end
  end
end
