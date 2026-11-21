defmodule NccWorker.Tracer.MixBase do
  @moduledoc """
  Mix's own modules that are loaded before the first dependency's compile
  runs any package code, on every way a user compiles a dependency, per
  toolchain (otp-probe round 4, the ruling on R2-6): measured, not listed by
  hand, by `priv/mix_base/measure.exs`, whose output (`priv/mix_base/<pair>.txt`)
  is checked in and embedded here at compile time (the worker is an
  escript, which carries no `priv`).

  The paths measured: `mix compile` in a new project with one dependency,
  `mix deps.compile`, and `Mix.install([dep])` in an `elixir -e` script;
  the list is their intersection. Livebook's runtime is not measured.

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
