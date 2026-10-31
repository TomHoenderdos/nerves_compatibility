defmodule Portal.Builders.AgentHarness do
  @moduledoc """
  Drives a real `ncc_agent` OS process against this test VM's portal, for
  the remote-builder end-to-end tests (`agent_e2e_test.exs` with the fake
  docker, `remote_integration_test.exs` with the real one).

  `start_portal!/1` configures a throwaway CA, upload root and `images.json`
  and starts Bandit with `PortalWeb.BuilderRouter` and the real listener TLS
  options on an ephemeral port (as `PortalWeb.BuilderListenerTLSTest` does),
  so the agent talks mTLS to the same router production serves.
  `start_agent!/2` runs `mix run --no-halt` in `apps/ncc_agent` with
  `MIX_ENV=test` and the agent's own boot (`load_config`) switched on;
  `await_lease/3` polls the lease while echoing the agent's output.

  Must be called from the test process (it registers `on_exit` callbacks and
  `start_supervised!` children).
  """
  import ExUnit.Assertions
  import ExUnit.Callbacks
  import Ecto.Query, only: [from: 2]

  require Ash.Query

  alias Portal.Builders.{CA, Lease, Leases, Listener, Upload}

  @umbrella Path.expand("../../../..", __DIR__)
  @agent_dir Path.join(@umbrella, "apps/ncc_agent")

  @spec umbrella() :: Path.t()
  def umbrella, do: @umbrella

  @spec fake_docker() :: Path.t()
  def fake_docker, do: Path.join(@agent_dir, "test/support/fake_docker.sh")

  @doc """
  CA, upload root, `images.json` (naming `image` with `digest`), a short
  claim long-poll and the builder listener on 127.0.0.1. Returns the temp
  dir and the port.
  """
  @spec start_portal!(%{image: String.t(), digest: String.t()}) :: %{
          dir: Path.t(),
          port: :inet.port_number()
        }
  def start_portal!(%{image: image, digest: digest}) do
    dir = Path.join(System.tmp_dir!(), "ncc-agent-e2e-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    key_path = Path.join([dir, "ca", "ca-key.pem"])
    images_json = Path.join(dir, "images.json")

    File.write!(
      images_json,
      Jason.encode!(%{"images" => %{"ncc-worker" => %{"name" => image, "digest" => digest}}})
    )

    put_env(CA, key_path: key_path)
    put_env(Upload, root: Path.join(dir, "uploads"))
    put_env(Portal.Builders.Images, path: images_json)
    put_env(Leases, long_poll_ms: 1_000)
    # The free-space floor is a property of the host, not of this test.
    put_env(Portal.Builder, min_free_disk_gb: 0)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, _} = CA.init(key_path)
    Portal.Builders.RateLimit.reset()

    opts =
      "localhost"
      |> Listener.https_options()
      |> Keyword.merge(port: 0, ip: {127, 0, 0, 1})

    server =
      start_supervised!(
        {Bandit, [plug: PortalWeb.BuilderRouter, scheme: :https, startup_log: false] ++ opts}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    %{dir: dir, port: port}
  end

  defp put_env(module, overrides) do
    previous = Application.get_env(:portal, module)
    Application.put_env(:portal, module, Keyword.merge(previous || [], overrides))

    on_exit(fn ->
      if previous,
        do: Application.put_env(:portal, module, previous),
        else: Application.delete_env(:portal, module)
    end)
  end

  @doc "A stand-in for `priv/egress.sh` that accepts every action (no `DOCKER-USER` here)."
  @spec egress_stub!(Path.t()) :: Path.t()
  def egress_stub!(dir) do
    path = Path.join(dir, "egress-stub.sh")
    File.write!(path, "#!/bin/sh\nexit 0\n")
    File.chmod!(path, 0o755)
    path
  end

  @doc """
  Spawn the agent with `env` on top of the portal URL and data dir. Returns
  the port; the agent is stopped (TERM, then KILL) in `on_exit`.
  """
  @spec start_agent!(%{dir: Path.t(), port: :inet.port_number()}, [{String.t(), String.t()}]) ::
          port()
  def start_agent!(%{dir: dir, port: port}, env) do
    data_dir = Path.join(dir, "agent-data")
    File.mkdir_p!(data_dir)

    env =
      [
        {"MIX_ENV", "test"},
        # `mix.exs` turns the agent's own boot off in test; this run is the
        # real agent, so switch it back on.
        {"ELIXIR_ERL_OPTIONS", "-ncc_agent load_config true"},
        {"NCC_PORTAL_URL", "https://localhost:#{port}"},
        {"NCC_DATA_DIR", data_dir},
        {"NCC_SLOTS", "1"},
        # Required: the agent refuses to start without a memory limit.
        {"NCC_MEMORY", "4g"}
      ] ++ env

    mix = System.find_executable("mix")
    assert mix, "no `mix` on PATH: the e2e tests spawn the agent with `mix run`"

    agent =
      Port.open({:spawn_executable, mix}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["run", "--no-halt"],
        cd: @agent_dir,
        env: Enum.map(env, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)
      ])

    {:os_pid, os_pid} = Port.info(agent, :os_pid)
    :persistent_term.put({__MODULE__, agent}, os_pid)

    # Once the port reported its exit the pid may already belong to another
    # process, so only a still-running agent is killed.
    on_exit(fn ->
      if :persistent_term.get({__MODULE__, :exited, os_pid}, false),
        do: :persistent_term.erase({__MODULE__, :exited, os_pid}),
        else: stop_os_pid(os_pid)

      :persistent_term.erase({__MODULE__, agent})
    end)

    agent
  end

  defp exited(agent) do
    case :persistent_term.get({__MODULE__, agent}, nil) do
      nil -> :ok
      os_pid -> :persistent_term.put({__MODULE__, :exited, os_pid}, true)
    end
  end

  @doc "Stop the agent: TERM (its slots hand leases back), then KILL after `grace_ms`."
  @spec stop_agent(port(), non_neg_integer()) :: :ok
  def stop_agent(agent, grace_ms \\ 10_000) do
    case Port.info(agent, :os_pid) do
      {:os_pid, os_pid} ->
        System.cmd("kill", ["-TERM", Integer.to_string(os_pid)], stderr_to_stdout: true)

        receive do
          {^agent, {:exit_status, _}} -> exited(agent)
        after
          grace_ms ->
            stop_os_pid(os_pid)

            receive do
              {^agent, {:exit_status, _}} -> exited(agent)
            after
              5_000 -> :ok
            end
        end

      nil ->
        :ok
    end

    :ok
  end

  defp stop_os_pid(os_pid) do
    System.cmd("kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)
    :ok
  end

  @doc """
  Poll the lease for `scan_request_id` every 500 ms until `done?` holds,
  echoing the agent's output as it arrives. Flunks with the output's tail
  when the agent exits, the lease fails or `timeout_ms` passes.
  """
  @spec await_lease(port(), Ecto.UUID.t(), (Lease.t() -> boolean()), pos_integer()) ::
          Lease.t()
  def await_lease(agent, scan_request_id, done?, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll(agent, scan_request_id, done?, deadline, "")
  end

  defp poll(agent, scan_request_id, done?, deadline, output) do
    output = drain(agent, output, 500)
    lease = lease_for(scan_request_id)

    cond do
      lease && done?.(lease) ->
        lease

      lease && lease.state == :failed ->
        flunk("lease failed: #{inspect(lease.error)}\n--- agent output ---\n#{tail(output)}")

      System.monotonic_time(:millisecond) > deadline ->
        flunk(
          "lease still #{inspect(lease && lease.state)} at the deadline\n" <>
            "--- agent output ---\n#{tail(output)}"
        )

      true ->
        poll(agent, scan_request_id, done?, deadline, output)
    end
  end

  defp drain(agent, output, wait_ms) do
    receive do
      {^agent, {:data, data}} ->
        IO.write(data)
        drain(agent, output <> data, 0)

      {^agent, {:exit_status, status}} ->
        exited(agent)
        flunk("the agent exited #{status}\n--- agent output ---\n#{tail(output)}")
    after
      wait_ms -> output
    end
  end

  defp tail(output),
    do: binary_part(output, max(byte_size(output) - 8_000, 0), min(byte_size(output), 8_000))

  defp lease_for(scan_request_id) do
    Lease
    |> Ash.Query.filter(scan_request_id == ^scan_request_id)
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(domain: Portal.Builders)
  end

  @doc "The `Ingest` job `JobController.complete/2` enqueued for `lease`, or nil."
  @spec ingest_job(Lease.t()) :: Oban.Job.t() | nil
  def ingest_job(%Lease{id: id}) do
    Portal.Repo.one(
      from(j in Oban.Job,
        where: j.worker == "Portal.Workers.Ingest" and fragment("?->>'lease_id' = ?", j.args, ^id)
      )
    )
  end
end
