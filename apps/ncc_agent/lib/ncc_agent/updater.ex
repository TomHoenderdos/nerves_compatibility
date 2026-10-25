defmodule NccAgent.Updater do
  @moduledoc """
  Self-update from a claim. When the portal's `min_agent_version` is newer
  than this release and it names a release for this architecture, the
  tarball is downloaded to `<releases>/<version>.tar.gz`, checked against
  its sha256, extracted to `<releases>/<version>/` (the release itself is
  `<releases>/<version>/ncc_agent`), and `<releases>/current` is swapped to
  it in one rename. The VM then stops and systemd starts the new release.

  A failed download, a hash mismatch or a bad tarball is logged and the
  agent carries on with the current version.
  """

  require Logger

  alias NccAgent.{Config, Version}

  @version ~r/\A[0-9A-Za-z][0-9A-Za-z._-]*\z/

  @type opts :: [
          current: String.t(),
          stop_fun: (-> any()),
          req_options: keyword()
        ]

  @spec maybe_update(map(), Config.t(), opts()) :: :ok | {:updating, String.t()}
  def maybe_update(claim, config, opts \\ []) do
    current = Keyword.get(opts, :current, Version.current())
    version = claim["min_agent_version"]

    with true <- Version.newer?(version, current),
         true <- Regex.match?(@version, version),
         %{"url" => url, "sha256" => sha} when is_binary(url) and is_binary(sha) <-
           get_in(claim, ["agent_releases", arch()]) do
      update(config, version, url, String.downcase(sha), opts)
    else
      _ -> :ok
    end
  end

  @doc "This VM's architecture as the portal names it: `x86_64` or `aarch64`."
  @spec arch() :: String.t()
  def arch do
    arch = to_string(:erlang.system_info(:system_architecture))

    cond do
      String.starts_with?(arch, "x86_64") -> "x86_64"
      String.starts_with?(arch, "aarch64") -> "aarch64"
      true -> arch
    end
  end

  # Every path is under the operator's releases dir; `version` is checked
  # against @version above.
  # sobelow_skip ["Traversal.FileModule"]
  defp update(config, version, url, sha, opts) do
    releases = Config.path(config, :releases)
    tarball = Path.join(releases, version <> ".tar.gz")
    dir = Path.join(releases, version)

    Logger.info("agent #{Version.current()} updating to #{version} from #{url}")

    result =
      with :ok <- File.mkdir_p(releases),
           :ok <- download(url, tarball, Keyword.get(opts, :req_options, [])),
           :ok <- verify(tarball, sha),
           :ok <- extract(tarball, dir) do
        swap(releases, version)
      end

    File.rm(tarball)

    case result do
      :ok ->
        Logger.info("agent release #{version} is current; restarting into it")
        Keyword.get(opts, :stop_fun, fn -> System.stop(0) end).()
        {:updating, version}

      {:error, reason} ->
        Logger.error("agent update to #{version} failed: #{inspect(reason)}")
        File.rm_rf(dir)
        :ok
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp download(url, tarball, req_options) do
    File.rm(tarball)

    [url: url, into: File.stream!(tarball), retry: false, receive_timeout: 120_000]
    |> Keyword.merge(req_options)
    |> Req.get()
    |> case do
      {:ok, %Req.Response{status: 200}} -> :ok
      {:ok, %Req.Response{status: status}} -> {:error, {:http, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp verify(tarball, sha) do
    actual =
      tarball
      |> File.stream!(65_536)
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)

    if actual == sha, do: :ok, else: {:error, {:sha256_mismatch, actual}}
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp extract(tarball, dir) do
    File.rm_rf(dir)

    with :ok <- File.mkdir_p(dir),
         :ok <-
           :erl_tar.extract(String.to_charlist(tarball), [:compressed, {:cwd, to_charlist(dir)}]) do
      if File.dir?(Path.join(dir, "ncc_agent")), do: :ok, else: {:error, :no_ncc_agent_dir}
    end
  end

  # A relative link, replaced by a rename so `current` always names a
  # whole release.
  # sobelow_skip ["Traversal.FileModule"]
  defp swap(releases, version) do
    tmp = Path.join(releases, ".current.tmp")
    File.rm(tmp)

    with :ok <- File.ln_s(Path.join(version, "ncc_agent"), tmp) do
      File.rename(tmp, Path.join(releases, "current"))
    end
  end
end
