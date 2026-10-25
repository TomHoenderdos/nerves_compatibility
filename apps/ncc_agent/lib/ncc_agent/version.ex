defmodule NccAgent.Version do
  @moduledoc """
  The agent's version, `"<unix seconds>.<git sha>"` for a release built by
  CI, fixed when the agent is compiled from `NCC_AGENT_VERSION`. A build
  without it is `"0.dev"`, which `newer?/2` never updates.
  """

  @version System.get_env("NCC_AGENT_VERSION") || "0.dev"

  @spec current() :: String.t()
  def current, do: @version

  @doc """
  Whether `candidate` is a newer release than `current`, comparing the
  integer before the first `.`. Unparsable versions are never newer, and a
  current version of `0` (a dev build) is never replaced.
  """
  @spec newer?(String.t() | nil, String.t() | nil) :: boolean()
  def newer?(candidate, current) do
    with {:ok, c} <- leading(candidate),
         {:ok, n} when n > 0 <- leading(current) do
      c > n
    else
      _ -> false
    end
  end

  defp leading(version) when is_binary(version) do
    [head | _] = String.split(version, ".", parts: 2)

    case Integer.parse(head) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> :error
    end
  end

  defp leading(_), do: :error
end
