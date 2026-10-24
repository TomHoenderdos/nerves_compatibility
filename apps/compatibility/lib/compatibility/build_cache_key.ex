defmodule Compatibility.BuildCacheKey do
  @moduledoc """
  The dependency build cache key, shared by the worker that computes it inside
  the build container and the portal that recomputes it on the host before
  promoting a candidate into the cache.

  One implementation on purpose: the host trusts a candidate only when its own
  computation, with the dependency name forced to the package under test,
  equals the key the container reported. Two copies of this function drifting
  by one byte would refuse every candidate, or worse, accept the wrong ones.

  The text hashed is one line per field, in this order:

      v2
      elixir=<System.version()>
      otp=<otp release>
      target=<host | any | mix target>
      dep=<name> <lock string>
      <closure name> <lock string>      (one per closure member, sorted)

  where a lock string is `"version inner_checksum outer_checksum"` (or
  `"version inner_checksum"`, or `"unlocked"`). The format and the `v2` are
  load-bearing: production caches hold entries under keys made this way.
  """

  @version "v2"

  @type inputs :: %{
          elixir: String.t(),
          otp: String.t(),
          target: String.t(),
          dep: String.t(),
          dep_lock: String.t(),
          closure: [{String.t(), String.t()}]
        }

  @spec key(inputs()) :: {:ok, String.t()} | :error
  def key(%{
        elixir: elixir,
        otp: otp,
        target: target,
        dep: dep,
        dep_lock: dep_lock,
        closure: closure
      }) do
    strings = [elixir, otp, target, dep, dep_lock | Enum.flat_map(closure, &Tuple.to_list/1)]

    if Enum.all?(strings, &single_line?/1) do
      {:ok,
       [
         @version,
         "elixir=" <> elixir,
         "otp=" <> otp,
         "target=" <> target,
         "dep=" <> dep <> " " <> dep_lock
       ]
       |> Enum.concat(
         closure
         |> Enum.map(fn {name, lock} -> name <> " " <> lock end)
         |> Enum.sort()
       )
       |> Enum.join("\n")
       |> then(&:crypto.hash(:sha256, &1))
       |> Base.encode16(case: :lower)}
    else
      :error
    end
  end

  def key(_), do: :error

  defp single_line?(s) when is_binary(s), do: not String.contains?(s, ["\n", "\r"])
  defp single_line?(_), do: false
end
