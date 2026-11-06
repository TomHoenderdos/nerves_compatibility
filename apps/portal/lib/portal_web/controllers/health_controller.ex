defmodule PortalWeb.HealthController do
  @moduledoc """
  `GET /health`: which build and which colour answers, and whether it holds
  the builder port. `ops/blue-green.sh` polls it on the idle colour's port and
  then through Apache; it switches only when `sha` is the commit it built. No
  database call, so a slow database cannot fail a switch.
  """
  use PortalWeb, :controller

  @build_sha Application.compile_env(:portal, :build_sha)

  def show(conn, _params) do
    json(conn, %{
      sha: @build_sha,
      color: color(node()),
      builder_endpoint: builder_endpoint(PortalWeb.BuilderEndpoint.Starter.status())
    })
  end

  @doc "The blue/green colour of a node named `portal_<color>@host`, else nil."
  @spec color(node()) :: String.t() | nil
  def color(node) do
    case Regex.run(~r/\Aportal_(blue|green)@/, Atom.to_string(node)) do
      [_, color] -> color
      _ -> nil
    end
  end

  defp builder_endpoint(:bound), do: "bound"
  defp builder_endpoint(:off), do: "off"
  defp builder_endpoint({:waiting, _since}), do: "waiting"
end
