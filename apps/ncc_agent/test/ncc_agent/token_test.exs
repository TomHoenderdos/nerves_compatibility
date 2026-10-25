defmodule NccAgent.TokenTest do
  use ExUnit.Case, async: true
  alias NccAgent.Token

  test "parses the three parts" do
    assert {:ok, %{id: "0f2b", secret: "c2VjcmV0", ca_prefix: "0123456789abcdef"}} =
             Token.parse("0f2b.c2VjcmV0.0123456789abcdef")
  end

  test "rejects anything else" do
    assert :error = Token.parse("a.b")
    assert :error = Token.parse("a.b.NOTHEX0123456789")
    assert :error = Token.parse("")
  end

  test "trims surrounding whitespace" do
    assert {:ok, %{ca_prefix: "0123456789abcdef"}} =
             Token.parse("0f2b.c2VjcmV0.0123456789abcdef\n")
  end
end
