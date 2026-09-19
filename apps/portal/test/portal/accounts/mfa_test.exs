defmodule Portal.Accounts.MfaTest do
  use Portal.DataCase, async: false

  import Portal.Test.AccountsFixtures

  alias Portal.Accounts.{Mfa, Passkeys, Totp}

  @now 1_789_000_000

  defp with_passkey(user) do
    {:ok, _} =
      Passkeys.create(user, %{
        credential_id: :crypto.strong_rand_bytes(16),
        public_key: :erlang.term_to_binary(%{3 => -7}),
        nickname: "laptop"
      })

    user
  end

  defp with_totp(user) do
    at = ~U[2026-09-18 12:00:00.000000Z]
    {:ok, %{secret: secret}} = Totp.start_enrolment(user)
    :ok = Totp.confirm(user, NimbleTOTP.verification_code(secret, time: at), at)
    user
  end

  test "factors report what the account actually holds" do
    bare = user_fixture()
    assert Mfa.factors(bare) == %{passkeys: 0, totp: false}
    refute Mfa.enrolled?(bare)

    keyed = with_passkey(user_fixture())
    assert Mfa.factors(keyed) == %{passkeys: 1, totp: false}
    assert Mfa.enrolled?(keyed)

    coded = with_totp(user_fixture())
    assert Mfa.factors(coded) == %{passkeys: 0, totp: true}
    assert Mfa.enrolled?(coded)
  end

  test "an unconfirmed TOTP secret is not a factor" do
    user = user_fixture()
    {:ok, _} = Totp.start_enrolment(user)

    assert Mfa.factors(user) == %{passkeys: 0, totp: false}
    refute Mfa.enrolled?(user)
  end

  test "only a passkey satisfies an admin" do
    refute Mfa.admin_satisfied?(admin_fixture())
    refute Mfa.admin_satisfied?(with_totp(admin_fixture()))
    assert Mfa.admin_satisfied?(with_passkey(admin_fixture()))

    # Non-admins are never subject to the check at all.
    assert Mfa.admin_satisfied?(user_fixture())
  end

  test "a confirmed TOTP is what makes a password login two-phase" do
    refute Mfa.second_factor_required?(user_fixture())
    refute Mfa.second_factor_required?(with_passkey(user_fixture()))
    assert Mfa.second_factor_required?(with_totp(user_fixture()))
  end

  test "the password authorises a factor change only while no factor exists" do
    assert Mfa.accepted_reauth_methods(user_fixture()) == [:password]
    assert Mfa.accepted_reauth_methods(with_passkey(user_fixture())) == [:passkey, :recovery_code]
    assert Mfa.accepted_reauth_methods(with_totp(user_fixture())) == [:totp, :recovery_code]

    # A passkey holder is held to the passkey even if they also have TOTP: an
    # account is only as strong as the weakest credential that can change it.
    both = user_fixture() |> with_passkey() |> with_totp()
    assert Mfa.accepted_reauth_methods(both) == [:passkey, :recovery_code]
  end

  test "freshness needs an accepted method inside the ten-minute window" do
    user = with_passkey(user_fixture())

    assert Mfa.reauth_fresh?(user, :passkey, @now, @now)
    assert Mfa.reauth_fresh?(user, :passkey, @now - 599, @now)
    assert Mfa.reauth_fresh?(user, :recovery_code, @now - 10, @now)

    refute Mfa.reauth_fresh?(user, :passkey, @now - 601, @now)
    refute Mfa.reauth_fresh?(user, :password, @now, @now)
    refute Mfa.reauth_fresh?(user, :totp, @now, @now)
    refute Mfa.reauth_fresh?(user, nil, @now, @now)
    refute Mfa.reauth_fresh?(user, :passkey, nil, @now)
  end

  test "the password stops working the moment the first factor lands" do
    user = user_fixture()
    assert Mfa.reauth_fresh?(user, :password, @now, @now)

    keyed = with_passkey(user)
    refute Mfa.reauth_fresh?(keyed, :password, @now, @now)
  end

  test "a timestamp from the future is not fresh" do
    user = user_fixture()
    refute Mfa.reauth_fresh?(user, :password, @now + 60, @now)
  end
end
