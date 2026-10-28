defmodule Portal.Builders.Images do
  @moduledoc """
  The registry digests and agent releases CI published for the deployed
  commit, read from `images.json` (the path `NCC_IMAGES_JSON` points at,
  written by `ops/images-sync.sh`).

  A remote lease carries the registry digest from here, so every builder
  means the same image by it. Missing or malformed, every reader answers nil
  and `Portal.Builders.Routing` keeps work local; nothing here ever raises.
  """

  @digest ~r/\Asha256:[0-9a-f]{64}\z/
  @sha256 ~r/\A[0-9a-f]{64}\z/

  @spec path() :: Path.t()
  def path do
    :portal
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:path, "/etc/ncc-portal/images.json")
  end

  @spec load() :: {:ok, map()} | {:error, :missing | :invalid}
  # The path is operator configuration, never request input.
  # sobelow_skip ["Traversal.FileModule"]
  def load do
    with {:ok, bytes} <- File.read(path()),
         {:ok, %{} = doc} <- Jason.decode(bytes) do
      {:ok, doc}
    else
      {:error, :enoent} -> {:error, :missing}
      _ -> {:error, :invalid}
    end
  end

  @spec worker_image() :: %{name: String.t(), digest: String.t(), tag: String.t()} | nil
  def worker_image do
    with {:ok, doc} <- load(),
         %{"name" => name, "digest" => digest} = image <- get_in(doc, ["images", "ncc-worker"]),
         true <- is_binary(name) and is_binary(digest) and Regex.match?(@digest, digest) do
      %{name: name, digest: digest, tag: Map.get(image, "tag")}
    else
      _ -> nil
    end
  end

  @spec agent() ::
          %{
            version: String.t(),
            releases: %{String.t() => %{url: String.t(), sha256: String.t()}}
          }
          | nil
  def agent do
    with {:ok, doc} <- load(),
         %{"version" => version, "releases" => %{} = releases} <- Map.get(doc, "agent"),
         true <- is_binary(version) do
      # The agent downloads and runs what these name (after checking the
      # sha256): only https URLs and well-formed digests leave this file.
      releases =
        for {arch, %{"url" => url, "sha256" => sha}} <- releases,
            is_binary(url) and String.starts_with?(url, "https://") and
              is_binary(sha) and Regex.match?(@sha256, sha),
            into: %{},
            do: {arch, %{url: url, sha256: sha}}

      %{version: version, releases: releases}
    else
      _ -> nil
    end
  end

  @spec min_agent_version() :: String.t() | nil
  def min_agent_version do
    case agent() do
      %{version: version} -> version
      nil -> nil
    end
  end
end
