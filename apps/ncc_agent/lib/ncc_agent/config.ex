defmodule NccAgent.Config do
  @moduledoc "The agent's configuration, from `/etc/ncc-agent.env` through the environment."

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
          egress_script: Path.t()
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
      egress_script: Path.join(to_string(:code.priv_dir(:ncc_agent)), "egress.sh")
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
        egress_script: System.get_env("NCC_EGRESS_SCRIPT") || defaults.egress_script
    }

    {slots, slot_errors} = parse_slots(System.get_env("NCC_SLOTS", "1"))
    errors = url_errors(config.portal_url) ++ slot_errors
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
  def path(config, :hex_cache), do: Path.join(config.data_dir, "hex-cache")
  def path(config, :releases), do: Path.join(config.data_dir, "releases")

  defp url_errors(nil), do: ["NCC_PORTAL_URL is required (https://host:8443)"]
  defp url_errors("https://" <> _), do: []
  defp url_errors(_), do: ["NCC_PORTAL_URL must be an https URL"]

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
