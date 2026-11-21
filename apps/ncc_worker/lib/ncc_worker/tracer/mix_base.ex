defmodule NccWorker.Tracer.MixBase do
  @moduledoc """
  The modules every way a user compiles a dependency has loaded by the
  earliest point package code runs, the evaluation of the first
  dependency's `mix.exs`, per toolchain (otp-probe round 4, the ruling on
  R2-6; measured at `mix.exs` and for every module, not only Mix's, since
  round 5, R3-4 and R3-8): measured, not listed by hand, by
  `priv/mix_base/measure.exs`, whose output (`priv/mix_base/<pair>.txt`)
  is checked in and embedded here at compile time (the worker is an
  escript, which carries no `priv`).

  The paths measured: `mix compile` in a new project with one dependency,
  `mix deps.compile`, and `Mix.install([dep])` in an `elixir -e` script,
  each in two environments: as the measuring shell has it, and with
  Erlang's own resolver (`ERL_INETRC` `{lookup, [file, dns]}`), since
  `inet_gethost_native` is loaded on the builder image's default setup but
  not on every user's machine (round 6, R5-3). The list is their
  intersection. Livebook's runtime is not measured.

  `Version`, `Version.Parser`, `Version.Requirement`, `Kernel.Utils`,
  `List.Chars` and `List.Chars.BitString` are in the list because the Hex
  archive loads them: Hex is started before any Hex dependency's `mix.exs`
  is evaluated, so every compile of a Hex package has them loaded. A
  project with no Hex archive would not, but it cannot compile a Hex
  package at all.

  The tracer takes a module of this list as loaded for the user too, when
  it was loaded before the tracer started (`NccWorker.Tracer`'s base list):
  a probe of it is not traced. A toolchain with no list has none: only the
  bare VM's modules are.
  """

  @dir Path.expand("../../../priv/mix_base", __DIR__)
  @files Path.wildcard(Path.join(@dir, "*.txt"))
  for file <- @files, do: @external_resource(file)

  @lists Map.new(@files, fn file ->
           modules =
             file
             |> File.read!()
             |> String.split("\n", trim: true)
             |> Enum.reject(&String.starts_with?(&1, "#"))
             |> Enum.sort()

           {Path.basename(file, ".txt"), modules}
         end)

  @doc "The measured list of the toolchain `pair` (`\"1.20-29\"`), sorted; `[]` for one not measured."
  @spec modules(String.t()) :: [String.t()]
  def modules(pair) when is_binary(pair), do: Map.get(@lists, pair, [])

  @doc "The toolchain pair of an Elixir version and an OTP release: `1.20-29`."
  @spec pair(String.t(), String.t()) :: String.t()
  def pair(elixir_version, otp_release) do
    [major, minor | _] = String.split(elixir_version, [".", "-"])
    "#{major}.#{minor}-#{otp_release}"
  end
end
