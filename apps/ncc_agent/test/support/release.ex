defmodule NccAgent.Test.Release do
  @moduledoc "A tiny agent release tarball (`ncc_agent/bin/ncc_agent`) for updater tests."

  @doc "Builds the tarball under `dir`; returns `{binary, sha256_hex}`."
  def tarball(dir) do
    src = Path.join(dir, "release-src")
    bin = Path.join(src, "ncc_agent/bin/ncc_agent")
    File.mkdir_p!(Path.dirname(bin))
    File.write!(bin, "#!/bin/sh\necho new\n")
    out = Path.join(dir, "release.tar.gz")

    :ok =
      :erl_tar.create(
        String.to_charlist(out),
        [{~c"ncc_agent/bin/ncc_agent", String.to_charlist(bin)}],
        [:compressed]
      )

    body = File.read!(out)
    {body, :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)}
  end

  @doc "The architecture key `NccAgent.Updater` looks up."
  def arch, do: NccAgent.Updater.arch()
end
