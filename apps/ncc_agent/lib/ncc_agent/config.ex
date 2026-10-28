defmodule NccAgent.Config do
  @moduledoc "The agent's configuration, read from the environment (an EnvironmentFile populates it under systemd in production)."

  @type t :: %{
          portal_url: String.t() | nil,
          enrolment_token: String.t() | nil,
          slots: pos_integer(),
          cpus: String.t() | nil,
          memory: String.t() | nil,
          build_concurrency: String.t() | nil,
          data_dir: Path.t(),
          build_user: String.t(),
          docker_bin: String.t(),
          egress_script: Path.t(),
          # `NCC_HEX_CACHE_RW=1`: the one-release rollback to a read-write
          # Hex cache mount (`Compatibility.Builder.Argv`).
          hex_cache_rw: boolean(),
          # The slot a job runs in, set by `NccAgent.Slot` on the job's copy.
          slot: pos_integer() | nil
        }

  @doc "Every default, with no portal URL."
  @spec defaults() :: t()
  def defaults do
    %{
      portal_url: nil,
      enrolment_token: nil,
      slots: 1,
      cpus: nil,
      memory: nil,
      build_concurrency: nil,
      data_dir: "/srv/ncc",
      build_user: own_user(),
      docker_bin: "docker",
      egress_script: Path.join(to_string(:code.priv_dir(:ncc_agent)), "egress.sh"),
      hex_cache_rw: false,
      slot: nil
    }
  end

  @spec load() :: {:ok, t()} | {:error, [String.t()]}
  def load do
    defaults = defaults()

    config = %{
      defaults
      | portal_url: System.get_env("NCC_PORTAL_URL"),
        enrolment_token: System.get_env("NCC_ENROLMENT_TOKEN"),
        cpus: System.get_env("NCC_CPUS"),
        memory: System.get_env("NCC_MEMORY"),
        build_concurrency: System.get_env("NCC_BUILD_CONCURRENCY"),
        data_dir: System.get_env("NCC_DATA_DIR", defaults.data_dir),
        build_user: System.get_env("NCC_BUILD_USER") || defaults.build_user,
        docker_bin: System.get_env("NCC_DOCKER_BIN", defaults.docker_bin),
        egress_script: System.get_env("NCC_EGRESS_SCRIPT") || defaults.egress_script,
        hex_cache_rw: System.get_env("NCC_HEX_CACHE_RW") == "1"
    }

    {slots, slot_errors} = parse_slots(System.get_env("NCC_SLOTS", "1"))
    errors = url_errors(config.portal_url) ++ slot_errors ++ user_errors(config.build_user)
    if errors == [], do: {:ok, %{config | slots: slots}}, else: {:error, errors}
  end

  @spec put(t()) :: :ok
  def put(config), do: :persistent_term.put({__MODULE__, :config}, config)

  @spec get() :: t()
  def get, do: :persistent_term.get({__MODULE__, :config})

  @spec path(t(), atom()) :: Path.t()
  def path(config, :ca), do: Path.join(config.data_dir, "ca.pem")
  def path(config, :cert), do: Path.join(config.data_dir, "client.pem")
  def path(config, :key), do: Path.join(config.data_dir, "client-key.pem")
  def path(config, :csr), do: Path.join(config.data_dir, "client.csr")
  def path(config, :scratch), do: Path.join(config.data_dir, "scratch")
  def path(config, :nerves_cache), do: Path.join(config.data_dir, "nerves-cache")
  # One Hex cache per slot: the scrub before a run (`NccAgent.HexCache`)
  # only holds when no other slot's container is writing the same dir
  # meanwhile, as builds did before the mount was read-only. Each slot's
  # promotion writes only its own dir too.
  def path(%{slot: n} = config, :hex_cache) when is_integer(n),
    do: Path.join([config.data_dir, "hex-cache", "slot-#{n}"])

  def path(config, :hex_cache), do: Path.join(config.data_dir, "hex-cache")
  def path(config, :releases), do: Path.join(config.data_dir, "releases")

  defp url_errors(nil), do: ["NCC_PORTAL_URL is required (https://host:8443)"]

  defp url_errors(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" -> []
      _ -> ["NCC_PORTAL_URL must be an https URL with a host, got #{inspect(url)}"]
    end
  end

  # The agent runs as root (systemd), so an unset NCC_BUILD_USER would run
  # every build container as uid 0 on the bind mounts; the release refuses
  # to start rather than do that quietly.
  defp user_errors(user) do
    with [uid, gid] <- String.split(user, ":"),
         {uid, ""} when uid >= 0 <- Integer.parse(uid),
         {_gid, ""} <- Integer.parse(gid) do
      if uid == 0,
        do: [
          "NCC_BUILD_USER must name a non-root uid (the container would build as root); set it to the ncc-build user's uid:gid"
        ],
        else: []
    else
      _ -> ["NCC_BUILD_USER must be uid:gid, got #{inspect(user)}"]
    end
  end

  defp parse_slots(value) do
    case Integer.parse(value) do
      {n, ""} when n in 1..16 -> {n, []}
      _ -> {1, ["NCC_SLOTS must be 1..16, got #{inspect(value)}"]}
    end
  end

  defp own_user do
    with {uid, 0} <- System.cmd("id", ["-u"]),
         {gid, 0} <- System.cmd("id", ["-g"]) do
      "#{String.trim(uid)}:#{String.trim(gid)}"
    else
      _ -> "1000:1000"
    end
  end
end
