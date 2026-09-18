defmodule Portal.Accounts.RecoveryCodesTest do
  use Portal.DataCase, async: false

  import Portal.Test.AccountsFixtures

  alias Portal.Accounts.RecoveryCodes

  test "generates ten formatted 80-bit codes" do
    user = user_fixture()

    assert {:ok, codes} = RecoveryCodes.generate(user)
    assert length(codes) == 10
    assert length(Enum.uniq(codes)) == 10

    for code <- codes do
      # 16 base32 characters in four dash-separated groups of four.
      assert Regex.match?(~r/^[a-z2-7]{4}-[a-z2-7]{4}-[a-z2-7]{4}-[a-z2-7]{4}$/, code)
    end

    assert RecoveryCodes.remaining(user) == 10
  end

  test "regenerating replaces every previous code" do
    user = user_fixture()
    {:ok, [old | _]} = RecoveryCodes.generate(user)
    {:ok, _new} = RecoveryCodes.generate(user)

    assert RecoveryCodes.remaining(user) == 10
    assert RecoveryCodes.consume(user, old) == {:error, :invalid_code}
  end

  test "a code works once and never again" do
    user = user_fixture()
    {:ok, [code | _]} = RecoveryCodes.generate(user)

    assert RecoveryCodes.consume(user, code) == :ok
    assert RecoveryCodes.remaining(user) == 9
    assert RecoveryCodes.consume(user, code) == {:error, :invalid_code}
  end

  test "input normalises case, dashes and surrounding whitespace" do
    user = user_fixture()
    {:ok, [code | _]} = RecoveryCodes.generate(user)

    mangled = "  " <> String.upcase(String.replace(code, "-", "")) <> "  "

    assert RecoveryCodes.consume(user, mangled) == :ok
  end

  test "one user's code does not work for another" do
    owner = user_fixture()
    stranger = user_fixture()
    {:ok, _} = RecoveryCodes.generate(stranger)
    {:ok, [code | _]} = RecoveryCodes.generate(owner)

    assert RecoveryCodes.consume(stranger, code) == {:error, :invalid_code}
    assert RecoveryCodes.remaining(owner) == 10
  end

  test "low? turns on at two remaining" do
    user = user_fixture()
    {:ok, codes} = RecoveryCodes.generate(user)

    refute RecoveryCodes.low?(user)

    codes |> Enum.take(7) |> Enum.each(&(:ok = RecoveryCodes.consume(user, &1)))
    refute RecoveryCodes.low?(user)

    :ok = RecoveryCodes.consume(user, Enum.at(codes, 7))
    assert RecoveryCodes.low?(user)
  end

  test "garbage is rejected without raising" do
    user = user_fixture()
    {:ok, _} = RecoveryCodes.generate(user)

    assert RecoveryCodes.consume(user, "") == {:error, :invalid_code}
    assert RecoveryCodes.consume(user, "not-a-real-code") == {:error, :invalid_code}
  end
end
