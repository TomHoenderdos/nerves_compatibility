defmodule Portal.Accounts.PasskeysTest do
  use Portal.DataCase, async: false

  import Portal.Test.AccountsFixtures

  alias Portal.Accounts.Passkeys

  describe "cose_key/1" do
    test "decodes a COSE map" do
      key = %{1 => 2, 3 => -7, -1 => 1, -2 => <<1, 2>>, -3 => <<3, 4>>}
      passkey = %Portal.Accounts.Passkey{public_key: :erlang.term_to_binary(key)}
      assert Passkeys.cose_key(passkey) == key
    end

    test "rejects executable terms nested in a stored key" do
      passkey = %Portal.Accounts.Passkey{
        public_key: :erlang.term_to_binary(%{1 => fn -> :ok end})
      }

      assert_raise ArgumentError, fn -> Passkeys.cose_key(passkey) end
    end
  end

  test "stores a credential and finds it by credential id" do
    user = user_fixture()

    {:ok, passkey} =
      Passkeys.create(user, %{
        credential_id: <<1, 2, 3>>,
        public_key: :erlang.term_to_binary(%{1 => 2, 3 => -7}),
        nickname: "laptop",
        aaguid: <<0::128>>,
        transports: ["internal"]
      })

    assert passkey.sign_count == 0
    assert passkey.user_id == user.id
    assert {:ok, found} = Passkeys.get_by_credential_id(<<1, 2, 3>>)
    assert found.id == passkey.id
    assert Passkeys.count_for_user(user) == 1
  end

  test "the same credential cannot be registered twice" do
    user = user_fixture()
    attrs = %{credential_id: <<9, 9>>, public_key: <<0>>, nickname: "one"}

    assert {:ok, _} = Passkeys.create(user, attrs)
    assert {:error, _} = Passkeys.create(user, %{attrs | nickname: "two"})
  end

  test "records use by advancing the sign count and stamping last_used_at" do
    user = user_fixture()

    {:ok, passkey} =
      Passkeys.create(user, %{credential_id: <<7>>, public_key: <<0>>, nickname: "k"})

    assert {:ok, updated} = Passkeys.record_use(passkey, 42)
    assert updated.sign_count == 42
    assert updated.last_used_at
  end

  test "delete only removes the caller's own passkey" do
    owner = user_fixture()
    stranger = user_fixture()

    {:ok, passkey} =
      Passkeys.create(owner, %{credential_id: <<5>>, public_key: <<0>>, nickname: "k"})

    assert Passkeys.delete(stranger, passkey.id) == {:error, :not_found}
    assert Passkeys.count_for_user(owner) == 1
    assert Passkeys.delete(owner, passkey.id) == :ok
    assert Passkeys.count_for_user(owner) == 0
  end

  # Counted in Postgres rather than by loading every row -- COSE public keys
  # included -- and calling `length/1`. This runs on every `/admin` request
  # through `RequireAdmin.check/2` and twice per `/settings/security` render.
  test "counting is scoped to the owner and correct" do
    owner = user_fixture()
    stranger = user_fixture()

    assert Passkeys.count_for_user(owner) == 0

    for n <- 1..3 do
      {:ok, _} =
        Passkeys.create(owner, %{
          credential_id: <<200, n>>,
          public_key: :erlang.term_to_binary(%{3 => -7}),
          nickname: "key #{n}"
        })
    end

    {:ok, _} =
      Passkeys.create(stranger, %{
        credential_id: <<201>>,
        public_key: <<0>>,
        nickname: "theirs"
      })

    assert Passkeys.count_for_user(owner) == 3
    assert Passkeys.count_for_user(stranger) == 1
  end

  test "a TOTP secret is unique per user and starts unconfirmed" do
    user = user_fixture()

    secret =
      Portal.Accounts.TotpSecret
      |> Ash.Changeset.for_create(:create, %{secret: NimbleTOTP.secret(), user_id: user.id})
      |> Ash.create!(domain: Portal.Accounts)

    assert is_nil(secret.confirmed_at)
    assert secret.failed_attempts == 0

    assert_raise Ash.Error.Invalid, fn ->
      Portal.Accounts.TotpSecret
      |> Ash.Changeset.for_create(:create, %{secret: NimbleTOTP.secret(), user_id: user.id})
      |> Ash.create!(domain: Portal.Accounts)
    end
  end

  test "a recovery code stores only a hash" do
    user = user_fixture()

    code =
      Portal.Accounts.RecoveryCode
      |> Ash.Changeset.for_create(:create, %{
        code_hash: String.duplicate("a", 64),
        user_id: user.id
      })
      |> Ash.create!(domain: Portal.Accounts)

    assert is_nil(code.used_at)
    refute Map.has_key?(code, :code)
  end
end
