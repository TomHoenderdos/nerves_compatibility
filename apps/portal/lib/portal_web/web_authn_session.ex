defmodule PortalWeb.WebAuthnSession do
  @moduledoc """
  Holds a `Wax.Challenge` between the two halves of a WebAuthn ceremony.

  The challenge lives in a node-local ETS table keyed by a random 16-byte id;
  only that id goes into the signed session. `take/2` reads it with
  `:ets.take/2`, which deletes and returns in one atomic operation, so a
  challenge is genuinely single-use: the second presentation finds nothing,
  whoever makes it and whatever cookie they carry.

  ## Why not the session itself

  Under `store: :cookie` (see `endpoint.ex`) the session *is* the signed
  cookie, so `delete_session/2` is only a `Set-Cookie` on the response —
  advisory, binding just the client that chooses to discard the superseded
  cookie. Anyone holding a copy of the pre-verify cookie could re-present the
  challenge for its whole five-minute life. That matters more than it sounds:
  `Portal.Accounts.WebAuthn.check_sign_count/2` returns `:ok` for a stored
  count of zero, which is what every synced passkey (iCloud Keychain, Google
  Password Manager) reports forever, so single use of the challenge is the
  only replay defence those authenticators have. Keeping the server's own
  record of what has been spent is what makes that defence real.

  Shrinking the session value from a serialised `%Wax.Challenge{}` to 16 bytes
  is a second, smaller win: the struct measured 1128 bytes of `Set-Cookie`,
  which an abandoned ceremony left on every request to the origin — including
  every asset fetch — for the rest of the browser session.

  ## The constraint this buys

  ETS is node-local. A challenge minted on one node cannot be verified on
  another, so a passkey ceremony must begin and end on the same instance.
  Production runs a single Phoenix instance, so this holds today. The day it
  does not — a second node, a rolling deploy that moves a session mid-ceremony
  — sign-in starts failing intermittently with "could not be verified", and
  the fix is a shared store (the database, or sticky sessions), not a longer
  TTL. The five-minute expiry is enforced here as well as by `wax_` itself.
  """

  use GenServer

  import Plug.Conn

  @table __MODULE__

  # Matches the `timeout: 300` in `Portal.Accounts.WebAuthn.opts/1`, which is
  # what `wax_` enforces against the challenge's own `issued_at`. This is the
  # server-side belt to that braces: it bounds how long a row can sit here.
  @ttl_seconds 300

  # Abandoned ceremonies are the common case -- dismissing the OS prompt makes
  # no second request -- so entries must be reaped rather than merely expired.
  @sweep_interval_ms :timer.seconds(60)

  @doc """
  Stashes `challenge` and puts only its id in the session under `key`.

  A challenge already stashed under `key` is dropped, so clicking the sign-in
  button twice leaves one row rather than two.
  """
  @spec put(Plug.Conn.t(), atom(), Wax.Challenge.t()) :: Plug.Conn.t()
  def put(conn, key, %Wax.Challenge{} = challenge) do
    discard(get_session(conn, key))

    id = :crypto.strong_rand_bytes(16)
    :ets.insert(@table, {id, challenge, System.system_time(:second)})

    put_session(conn, key, id)
  end

  @doc """
  Consumes the challenge stashed under `key`.

  Always clears the session key and always deletes the stored row, whether or
  not the challenge was still valid. The returned conn is the one the caller
  must carry forward.
  """
  @spec take(Plug.Conn.t(), atom()) ::
          {:ok, Wax.Challenge.t(), Plug.Conn.t()} | {:error, Plug.Conn.t()}
  def take(conn, key) do
    id = get_session(conn, key)
    conn = delete_session(conn, key)

    case id && :ets.take(@table, id) do
      [{^id, %Wax.Challenge{} = challenge, at}] when is_integer(at) ->
        # `elapsed >= 0` mirrors `PortalWeb.UserAuth.pending_user/1`: a clock
        # stepped backwards between `put/3` and `take/2` must not leave a
        # future-dated row valid forever.
        elapsed = System.system_time(:second) - at

        if elapsed >= 0 and elapsed <= @ttl_seconds do
          {:ok, challenge, conn}
        else
          {:error, conn}
        end

      _ ->
        {:error, conn}
    end
  end

  @doc false
  # The table name, for tests that need to inspect or age a stashed challenge.
  @spec table() :: atom()
  def table, do: @table

  @doc false
  @spec ttl_seconds() :: pos_integer()
  def ttl_seconds, do: @ttl_seconds

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    # `:public` so the request process inserts and takes directly -- this
    # process exists to own the table and sweep it, never to serialise access.
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    cutoff = System.system_time(:second) - @ttl_seconds
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)

  defp discard(id) when is_binary(id), do: :ets.delete(@table, id)
  defp discard(_), do: :ok
end
