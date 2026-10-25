defmodule NccAgent.Egress do
  @moduledoc """
  Placeholder for the builder's egress ruleset: always in place. Task 15
  replaces it with the real iptables chain (`priv/egress.sh`), its install
  and its verification.
  """

  @spec install() :: :ok
  def install, do: :ok

  @spec verify() :: :ok
  def verify, do: :ok

  @spec status() :: String.t()
  def status, do: "ok"
end
