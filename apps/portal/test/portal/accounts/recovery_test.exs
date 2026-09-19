defmodule Portal.Accounts.RecoveryTest do
  use Portal.DataCase, async: false

  import Portal.Test.AccountsFixtures

  alias Portal.Accounts.{Mfa, Passkeys, Recovery, RecoveryCodes, Totp}

  defp add_passkey(user, nickname) do
    {:ok, _} =
      Passkeys.create(user, %{
        credential_id: :crypto.strong_rand_bytes(16),
        public_key: :erlang.term_to_binary(%{3 => -7}),
        nickname: nickname
      })

    :ok
  end

  test "clearing factors removes every passkey and the authenticator app" do
    user = user_fixture()
    add_passkey(user, "laptop")
    add_passkey(user, "phone")
    {:ok, %{secret: secret}} = Totp.start_enrolment(user)
    :ok = Totp.confirm(user, NimbleTOTP.verification_code(secret))

    codes = Recovery.clear_factors!(user.username)

    assert Passkeys.count_for_user(user) == 0
    refute Totp.confirmed?(user)
    refute Mfa.enrolled?(user)
    assert length(codes) == 10
  end

  test "the returned codes work" do
    user = user_fixture()
    add_passkey(user, "laptop")

    [code | _] = Recovery.clear_factors!(user.username)

    assert RecoveryCodes.consume(user, code) == :ok
  end

  test "old recovery codes stop working" do
    user = user_fixture()
    add_passkey(user, "laptop")
    {:ok, [old | _]} = RecoveryCodes.generate(user)

    _new = Recovery.clear_factors!(user.username)

    assert RecoveryCodes.consume(user, old) == {:error, :invalid_code}
  end

  test "an account with no factors is still handled" do
    user = user_fixture()

    codes = Recovery.clear_factors!(user.username)

    assert length(codes) == 10
  end

  test "an unknown username raises" do
    assert_raise RuntimeError, ~r/nobody/, fn ->
      Recovery.clear_factors!("nobody")
    end
  end

  test "another account is untouched" do
    user = user_fixture()
    add_passkey(user, "laptop")
    bystander = user_fixture()
    add_passkey(bystander, "their laptop")

    _codes = Recovery.clear_factors!(user.username)

    assert Passkeys.count_for_user(bystander) == 1
  end
end
