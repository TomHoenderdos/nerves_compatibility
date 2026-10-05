defmodule Portal.Catalog.FindingTriageTest do
  use Portal.DataCase, async: true

  alias Portal.Catalog.FindingTriage

  @finding %{
    "analysis" => "mailbox",
    "severity" => "warning",
    "title" => "Timer cancelled without flushing its message",
    "file" => "lib/x/downloader.ex",
    "line" => 263,
    "detail" => "X.Downloader cancels the timer in X.Downloader.reschedule/1"
  }

  test "fingerprint ignores the line number" do
    assert FindingTriage.fingerprint("x", @finding) ==
             FindingTriage.fingerprint("x", %{@finding | "line" => 300})
  end

  test "fingerprint separates two findings of one class in one file" do
    refute FindingTriage.fingerprint("x", @finding) ==
             FindingTriage.fingerprint("x", %{@finding | "detail" => "X.Downloader.other/1"})
  end

  test "fingerprint separates packages" do
    refute FindingTriage.fingerprint("x", @finding) == FindingTriage.fingerprint("y", @finding)
  end

  test "fingerprint is lowercase hex sha256" do
    assert FindingTriage.fingerprint("x", @finding) =~ ~r/\A[0-9a-f]{64}\z/
  end
end
