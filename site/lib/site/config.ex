defmodule Site.Config do
  @moduledoc """
  Runtime-configurable URLs for the rendered site.

  Read via environment variables so the same build can be deployed to
  production, staging, or a localhost preview without rebuilding — the
  generator picks up the current values at site-gen time.

  | Var                     | Default                                  | Used for                               |
  | ----------------------- | ---------------------------------------- | -------------------------------------- |
  | SITE_BASE_URL           | https://compatibility.embedded-elixir.com | Canonical host for the compat tracker  |
  | PRECOMPILED_FILES_BASE  | (unset → same as SITE_BASE_URL + "/files") | Where /files/<sha256> blobs are served |
  | PRECOMPILED_MANIFESTS_BASE | (unset → same as SITE_BASE_URL + "/manifests") | Where /manifests/<pkg>.json is served |

  When the precompiled-binaries service moves to its own host (e.g.
  prebuilt.embedded-elixir.com), set PRECOMPILED_FILES_BASE and
  PRECOMPILED_MANIFESTS_BASE to that host; everything else stays put.
  """

  @default_site_base "https://compatibility.embedded-elixir.com"

  @doc "Canonical compat-site host (no trailing slash)."
  @spec site_base_url() :: String.t()
  def site_base_url() do
    case System.get_env("SITE_BASE_URL") do
      nil -> @default_site_base
      "" -> @default_site_base
      url -> String.trim_trailing(url, "/")
    end
  end

  @doc "Base URL for the precompiled-file content-addressed store."
  @spec precompiled_files_base() :: String.t()
  def precompiled_files_base() do
    env("PRECOMPILED_FILES_BASE") || site_base_url() <> "/files"
  end

  @doc "Base URL for precompiled-package manifests."
  @spec precompiled_manifests_base() :: String.t()
  def precompiled_manifests_base() do
    env("PRECOMPILED_MANIFESTS_BASE") || site_base_url() <> "/manifests"
  end

  defp env(key) do
    case System.get_env(key) do
      nil -> nil
      "" -> nil
      url -> String.trim_trailing(url, "/")
    end
  end
end
