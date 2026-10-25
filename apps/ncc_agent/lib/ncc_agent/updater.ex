defmodule NccAgent.Updater do
  @moduledoc """
  Self-update from a claim, one at a time for all slots. When the portal's
  `min_agent_version` is newer than this release and it names a release
  for this architecture, the tarball is downloaded to
  `<releases>/<version>.tar.gz`, checked against its sha256, extracted to
  `<releases>/<version>/` (the release itself is
  `<releases>/<version>/ncc_agent`), and `<releases>/current` is swapped to
  it in one rename. The VM then stops and systemd starts the new release.

  `maybe_update/3` is a call into this server. The download runs in a task
  so the server keeps answering: a second caller while an update is in
  progress, or once `current` already names the version, gets `:ok` at
  once. A successful update sets `updating?/0` for every slot, answers
  `{:updating, version}`, and stops the VM a few seconds later so the slot
  that claimed can hand its lease back first.

  A failed download, a hash mismatch, a bad tarball or a crash anywhere in
  it is logged and the agent carries on with the current version.
  """
  use GenServer

  require Logger

  alias NccAgent.{Config, Version}

  @version ~r/\A[0-9A-Za-z][0-9A-Za-z._-]*\z/
  @flag {__MODULE__, :updating}
  @stop_delay_ms 5_000

  @type opts :: [
          current: String.t(),
          stop_fun: (-> any()),
          stop_delay_ms: non_neg_integer(),
          req_options: keyword()
        ]

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec maybe_update(map(), Config.t(), opts()) :: :ok | {:updating, String.t()}
  def maybe_update(claim, config, opts \\ []) do
    GenServer.call(__MODULE__, {:maybe_update, claim, config, opts}, :infinity)
  catch
    :exit, reason ->
      Logger.error("the updater is unavailable: #{inspect(reason)}")
      :ok
  end

  @doc "Whether an update has been installed and the VM is about to restart into it."
  @spec updating?() :: boolean()
  def updating?, do: :persistent_term.get(@flag, false) != false

  @doc false
  # For tests that ran a successful update.
  def clear_updating, do: :persistent_term.erase(@flag)

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

  @impl true
  def init(_opts), do: {:ok, %{task: nil}}

  @impl true
  def handle_call({:maybe_update, claim, config, opts}, from, state) do
    with nil <- state.task,
         {:ok, version, url, sha} <- wanted(claim, config, opts) do
      task = Task.async(fn -> safe_update(config, version, url, sha, opts) end)
      {:noreply, %{state | task: %{ref: task.ref, from: from, version: version, opts: opts}}}
    else
      _ -> {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info({ref, result}, %{task: %{ref: ref} = task} = state) do
    Process.demonitor(ref, [:flush])

    case result do
      :ok ->
        :persistent_term.put(@flag, task.version)
        GenServer.reply(task.from, {:updating, task.version})
        delay = Keyword.get(task.opts, :stop_delay_ms, @stop_delay_ms)
        stop_fun = Keyword.get(task.opts, :stop_fun, fn -> System.stop(0) end)
        Process.send_after(self(), {:stop, stop_fun}, delay)

      {:error, reason} ->
        Logger.error("agent update to #{task.version} failed: #{inspect(reason)}")
        GenServer.reply(task.from, :ok)
    end

    {:noreply, %{state | task: nil}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %{ref: ref} = task} = state) do
    Logger.error("agent update to #{task.version} crashed: #{inspect(reason)}")
    GenServer.reply(task.from, :ok)
    {:noreply, %{state | task: nil}}
  end

  def handle_info({:stop, stop_fun}, state) do
    Logger.info("restarting into agent #{:persistent_term.get(@flag, "?")}")
    stop_fun.()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp wanted(claim, config, opts) do
    current = Keyword.get(opts, :current, Version.current())
    version = claim["min_agent_version"]

    with true <- Version.newer?(version, current),
         true <- Regex.match?(@version, version),
         false <- current?(config, version),
         %{"url" => url, "sha256" => sha} when is_binary(url) and is_binary(sha) <-
           get_in(claim, ["agent_releases", arch()]) do
      {:ok, version, url, String.downcase(sha)}
    else
      _ -> :skip
    end
  end

  # Already installed, waiting for the restart.
  defp current?(config, version) do
    link = config |> Config.path(:releases) |> Path.join("current") |> String.to_charlist()

    case :file.read_link(link) do
      {:ok, target} -> to_string(target) == Path.join(version, "ncc_agent")
      _ -> false
    end
  end

  defp safe_update(config, version, url, sha, opts) do
    update(config, version, url, sha, opts)
  rescue
    e -> {:error, {:crashed, Exception.message(e)}}
  catch
    kind, reason -> {:error, {kind, reason}}
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
    if result != :ok, do: File.rm_rf(dir)
    result
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
