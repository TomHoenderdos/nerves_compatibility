defmodule PortalWeb.HealthController do
  @moduledoc """
  `GET /health`: which build and which colour answers, and whether it holds
  the builder port. `ops/blue-green.sh` polls it on the idle colour's port and
  then through Apache; it switches only when `sha` is the commit it built. No
  database call, so a slow database cannot fail a switch.

  `sha` is read at runtime from a `BUILD_SHA` file at the release root
  (`:code.root_dir/0`), written by `ops/build-release.sh` right after it
  copies the release into place, and cached in `:persistent_term` after the
  first read. It is deliberately not compiled in: the host reuses `_build`
  across deploys, and a compile-time value here makes `mix release
  --overwrite` refuse to start on any deploy whose commit doesn't also touch
  this file, with "different value set for key :build_sha during runtime
  compared to compile time".
  """
  use PortalWeb, :controller

  @persistent_term_key {__MODULE__, :build_sha}

  def show(conn, _params) do
    json(conn, %{
      sha: cached_build_sha(),
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

  @doc false
  @spec build_sha(Path.t()) :: String.t() | nil
  # root_dir is :code.root_dir/0, the release's own root, never request input.
  # sobelow_skip ["Traversal.FileModule"]
  def build_sha(root_dir) do
    case File.read(Path.join(root_dir, "BUILD_SHA")) do
      {:ok, content} ->
        case String.trim(content) do
          "" -> nil
          sha -> sha
        end

      {:error, _} ->
        nil
    end
  end

  defp cached_build_sha do
    case :persistent_term.get(@persistent_term_key, :unset) do
      :unset ->
        sha = build_sha(to_string(:code.root_dir()))
        :persistent_term.put(@persistent_term_key, sha)
        sha

      sha ->
        sha
    end
  end

  defp builder_endpoint(:bound), do: "bound"
  defp builder_endpoint(:off), do: "off"
  defp builder_endpoint({:waiting, _since}), do: "waiting"
end
