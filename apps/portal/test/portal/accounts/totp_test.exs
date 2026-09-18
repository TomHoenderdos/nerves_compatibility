defmodule Portal.Accounts.TotpTest do
  use Portal.DataCase, async: false

  import Portal.Test.AccountsFixtures

  alias Portal.Accounts.Totp

  # Fixed clocks throughout: a test that asks the system what time it is will
  # eventually straddle a 30-second period boundary and fail for nobody's good.
  @t0 ~U[2026-09-18 12:00:00.000000Z]

  defp enrol(user, now \\ @t0) do
    {:ok, %{secret: secret}} = Totp.start_enrolment(user)
    :ok = Totp.confirm(user, NimbleTOTP.verification_code(secret, time: now), now)
    secret
  end

  test "enrolment yields a secret and an otpauth URI naming the portal" do
    user = user_fixture(%{username: "wrenchbird"})

    assert {:ok, %{secret: secret, uri: uri}} = Totp.start_enrolment(user)
    assert byte_size(secret) == 20
    assert String.starts_with?(uri, "otpauth://totp/")
    assert uri =~ "wrenchbird"
    assert uri =~ "issuer=Nerves"
  end

  test "an unconfirmed secret is not a factor" do
    user = user_fixture()
    {:ok, _} = Totp.start_enrolment(user)

    refute Totp.confirmed?(user)
  end

  test "one working code confirms the secret" do
    user = user_fixture()
    {:ok, %{secret: secret}} = Totp.start_enrolment(user)

    assert Totp.confirm(user, NimbleTOTP.verification_code(secret, time: @t0), @t0) == :ok
    assert Totp.confirmed?(user)
  end

  test "a wrong code does not confirm" do
    user = user_fixture()
    {:ok, _} = Totp.start_enrolment(user)

    assert Totp.confirm(user, "000000", @t0) == {:error, :invalid_code}
    refute Totp.confirmed?(user)
  end

  test "restarting enrolment discards the previous unconfirmed secret" do
    user = user_fixture()
    {:ok, %{secret: first}} = Totp.start_enrolment(user)
    {:ok, %{secret: second}} = Totp.start_enrolment(user)

    refute first == second

    assert Totp.confirm(user, NimbleTOTP.verification_code(first, time: @t0), @t0) ==
             {:error, :invalid_code}
  end

  test "a valid code verifies" do
    user = user_fixture()
    secret = enrol(user)
    later = DateTime.add(@t0, 60, :second)

    assert Totp.verify(user, NimbleTOTP.verification_code(secret, time: later), later) == :ok
  end

  test "a code cannot be replayed inside its own window" do
    user = user_fixture()
    secret = enrol(user)
    later = DateTime.add(@t0, 60, :second)
    code = NimbleTOTP.verification_code(secret, time: later)

    assert Totp.verify(user, code, later) == :ok
    assert Totp.verify(user, code, later) == {:error, :invalid_code}
  end

  test "a code from an old window is rejected" do
    user = user_fixture()
    secret = enrol(user)
    stale = NimbleTOTP.verification_code(secret, time: @t0)
    much_later = DateTime.add(@t0, 600, :second)

    assert Totp.verify(user, stale, much_later) == {:error, :invalid_code}
  end

  test "five failures lock the secret, and a correct code is refused while locked" do
    user = user_fixture()
    secret = enrol(user)
    later = DateTime.add(@t0, 60, :second)

    for _ <- 1..4 do
      assert Totp.verify(user, "000000", later) == {:error, :invalid_code}
    end

    assert {:error, {:locked, until}} = Totp.verify(user, "000000", later)
    assert DateTime.compare(until, later) == :gt

    good = NimbleTOTP.verification_code(secret, time: later)
    assert {:error, {:locked, ^until}} = Totp.verify(user, good, later)
  end

  test "the lock lifts and the counter resets once the window passes" do
    user = user_fixture()
    secret = enrol(user)
    later = DateTime.add(@t0, 60, :second)

    for _ <- 1..5, do: Totp.verify(user, "000000", later)

    after_lock = DateTime.add(later, 16 * 60, :second)

    assert Totp.verify(user, NimbleTOTP.verification_code(secret, time: after_lock), after_lock) ==
             :ok
  end

  test "a successful verification clears the failure counter" do
    user = user_fixture()
    secret = enrol(user)
    later = DateTime.add(@t0, 60, :second)

    assert Totp.verify(user, "000000", later) == {:error, :invalid_code}
    assert Totp.verify(user, NimbleTOTP.verification_code(secret, time: later), later) == :ok

    {:ok, stored} = Totp.get_secret(user)
    assert stored.failed_attempts == 0
  end

  test "verifying without enrolment says so" do
    user = user_fixture()

    assert Totp.verify(user, "000000", @t0) == {:error, :not_enrolled}
  end

  test "disable removes the secret entirely" do
    user = user_fixture()
    enrol(user)

    assert Totp.disable(user) == :ok
    refute Totp.confirmed?(user)
    assert Totp.get_secret(user) == :error
  end

  test "two concurrent verifications of the same code let exactly one win" do
    user = user_fixture()
    secret = enrol(user)
    later = DateTime.add(@t0, 60, :second)
    code = NimbleTOTP.verification_code(secret, time: later)

    parent = self()

    tasks =
      for _ <- 1..2 do
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.allow(Portal.Repo, parent, self())
          Totp.verify(user, code, later)
        end)
      end

    results = Task.await_many(tasks)

    assert Enum.count(results, &(&1 == :ok)) == 1
    assert Enum.count(results, &(&1 == {:error, :invalid_code})) == 1
  end

  test "two concurrent failed verifications both count toward the lockout" do
    user = user_fixture()
    enrol(user)
    later = DateTime.add(@t0, 60, :second)

    parent = self()

    tasks =
      for _ <- 1..2 do
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.allow(Portal.Repo, parent, self())
          Totp.verify(user, "000000", later)
        end)
      end

    Task.await_many(tasks)

    {:ok, stored} = Totp.get_secret(user)
    assert stored.failed_attempts == 2
  end
end
