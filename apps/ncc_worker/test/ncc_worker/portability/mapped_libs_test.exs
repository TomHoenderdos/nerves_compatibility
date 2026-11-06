defmodule NccWorker.Portability.MappedLibsTest do
  use ExUnit.Case, async: true

  alias NccWorker.Portability.MappedLibs

  @otp "/usr/local/lib/erlang"
  @libc "/usr/lib/aarch64-linux-gnu/libc.so.6"
  @crypto "/usr/local/lib/erlang/lib/crypto-5.9.2/priv/lib/crypto.so"
  @dep_nif "/w/proj/_build/host/lib/nat/priv/nat_nif.so"

  defp start(libs), do: %{"nif_check" => "ok", "mapped_libs" => libs}
  defp later(libs), do: %{"nif_check" => "ok", "mapped_libs" => libs}

  defp allowed?(path),
    do:
      String.starts_with?(path, @otp <> "/") or
        String.starts_with?(path, "/w/proj/_build/host/lib/nat/")

  test "a library mapped during the compile outside every allowed dir refuses" do
    assert {:refuse, "compile-time native library load: /tmp/evil.so"} =
             MappedLibs.check(start([@libc]), [later([@libc, "/tmp/evil.so"])], &allowed?/1)
  end

  test "libraries mapped before the first window opened are ignored, wherever they are" do
    assert {:ok, []} =
             MappedLibs.check(
               start([@libc, "/opt/x/libfoo.so"]),
               [later([@libc, "/opt/x/libfoo.so"])],
               &allowed?/1
             )
  end

  test "new libraries under the OTP root or a native closure dependency are observed, not refused" do
    assert {:ok, [@crypto, @dep_nif]} =
             MappedLibs.check(
               start([@libc]),
               [later([@libc, @crypto]), later([@libc, @dep_nif])],
               &allowed?/1
             )
  end

  test "a library mapped and unmapped again between two snapshots is still seen in the one that had it" do
    assert {:refuse, _} =
             MappedLibs.check(start([]), [later(["/tmp/a.so"]), later([])], &allowed?/1)
  end

  test "no maps at the start or at any later point is unavailable" do
    for {s, l} <- [
          {%{"nif_check" => "unavailable", "mapped_libs" => nil}, [later([])]},
          {start([]), [%{"nif_check" => "unavailable", "mapped_libs" => nil}]},
          {nil, [later([])]},
          {start([]), [nil]},
          {start([]), [%{"nif_check" => "ok", "mapped_libs" => "nope"}]},
          {start([]), []}
        ] do
      assert :unavailable = MappedLibs.check(s, l, &allowed?/1), inspect({s, l})
    end
  end

  test "the waiver is the test helper's environment variable and nothing else" do
    refute MappedLibs.waived?(%{})
    refute MappedLibs.waived?(%{"NCC_TRACE_ALLOW_NO_NIF_CHECK" => "true"})
    assert MappedLibs.waived?(%{"NCC_TRACE_ALLOW_NO_NIF_CHECK" => "1"})
  end
end
