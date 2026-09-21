defmodule PortalWeb.SecurityHTMLTest do
  use ExUnit.Case, async: true

  test "QR code output contains only encoded geometry, never the supplied markup" do
    input = "otpauth://totp/<script>alert(1)</script>?secret=AAAA"
    svg = input |> PortalWeb.SecurityHTML.totp_qr() |> Phoenix.HTML.safe_to_string()
    assert svg =~ "<svg"
    assert svg =~ "<rect"
    refute svg =~ "<script"
    refute svg =~ "otpauth"
  end
end
