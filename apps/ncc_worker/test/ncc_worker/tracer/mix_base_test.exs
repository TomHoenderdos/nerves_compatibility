defmodule NccWorker.Tracer.MixBaseTest do
  use ExUnit.Case, async: true

  alias NccWorker.Tracer.MixBase

  test "the measured list per toolchain the builders and CI run" do
    for pair <- ["1.19-28", "1.20-29", "1.20-28"] do
      modules = MixBase.modules(pair)
      # Measured at a dependency's mix.exs, every module (R3-4).
      for m <- ~w(Elixir.Mix Elixir.Mix.Project Elixir.Process Elixir.String Elixir.Version),
          do: assert(m in modules, "#{pair} #{m}")

      # Loaded by the mix command, not under Mix.install.
      refute "Elixir.Mix.CLI" in modules, pair
      assert modules == Enum.sort(modules)
    end
  end

  test "an unmeasured toolchain has no list" do
    assert MixBase.modules("1.17-26") == []
  end

  test "the pair of a version" do
    assert MixBase.pair("1.20.3", "29") == "1.20-29"
    assert MixBase.pair("1.19.3-rc.0", "28") == "1.19-28"
  end
end
