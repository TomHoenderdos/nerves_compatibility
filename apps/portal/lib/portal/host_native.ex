defmodule Portal.HostNative do
  @moduledoc """
  Host-native builds (board #85): a NIF package version built on a
  toolchain image for one glibc Linux triple (`Compatibility.HostTriple`),
  stored as `Portal.Catalog.HostNativeBuild`, and published in the format-2
  manifest's `builds_host_native` list, which only a client that opted in
  (`config :precompiled, host_native: true`) reads.

  Everything here is behind the `host_native_enabled` setting
  (`Portal.Settings`, off by default): with it off nothing is queued
  (`enqueue/3`), no manifest lists a host-native build (`served/3`), and
  `Portal.Catalog`'s SQL selectors (the files route, the package list, the
  batch fingerprints) leave them out by the same predicate. Rows ingested
  while it was on stay stored.

  The build runs on a builder of the triple's own architecture, never
  emulated: its queue is `host_native_<arch>` (`queue/1`), which a node
  that runs the `toolchain` queue also runs for its own architecture
  (`config/runtime.exs`). The worker reports the triple of the VM it ran
  in, and the ingest refuses one the job did not ask for.

  A build is served when it passed, is not revoked
  (`Portal.Precompiled.HostNativeRevocation`), is not withheld
  (`Portal.Precompiled.Withheld`, as for any build), and every file its
  manifest lists is a stored membership of it.
  """

  require Ash.Query

  alias Compatibility.HostTriple
  alias Portal.Catalog.{ArtifactMembership, HostNativeBuild, Package}
  alias Portal.Precompiled.Withheld

  @builder_version 1

  @doc "Whether host-native builds are queued and published."
  @spec enabled?() :: boolean()
  def enabled?, do: Portal.Settings.get().host_native_enabled == true

  @doc "The builder version a new host-native build is queued under."
  @spec builder_version() :: pos_integer()
  def builder_version, do: @builder_version

  @doc "The queue a triple's builds run on: one per architecture."
  @spec queue(term()) :: {:ok, String.t()} | :error
  def queue(triple) do
    case HostTriple.elf_machine(triple) do
      {:ok, arch} -> {:ok, "host_native_#{arch}"}
      :error -> :error
    end
  end

  @doc """
  This node's own triple: its VM's (`Compatibility.HostTriple.current/0`),
  or `config :portal, Portal.HostNative, triple:` (tests).
  """
  @spec own_triple() :: {:ok, String.t()} | :error
  def own_triple do
    case Application.get_env(:portal, __MODULE__, [])[:triple] do
      nil -> HostTriple.current()
      triple -> if HostTriple.valid?(triple), do: {:ok, triple}, else: :error
    end
  end

  @doc "The queue this node's own architecture builds on, when it has one."
  @spec local_queue() :: String.t() | nil
  def local_queue do
    case own_triple() do
      {:ok, triple} -> triple |> queue() |> elem(1)
      :error -> nil
    end
  end

  @doc """
  Queues a host-native build of `package` `version`. Options: `:triple`
  (default `"x86_64-linux-gnu"`), `:toolchain` (default the first configured
  toolchain, `Portal.Toolchains.images/0`). `{:error, :disabled}` while the
  setting is off, `{:error, :unknown_triple}` or `{:error, :unknown_toolchain}`
  for inputs no builder serves.
  """
  @spec enqueue(String.t(), String.t(), keyword()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(package, version, opts \\ []) do
    triple = Keyword.get(opts, :triple, "x86_64-linux-gnu")

    with true <- enabled?() || {:error, :disabled},
         {:ok, queue} <- queue_of(triple),
         {:ok, toolchain} <- toolchain(Keyword.get(opts, :toolchain)) do
      %{
        "package" => package,
        "version" => version,
        "toolchain" => toolchain,
        "triple" => triple,
        "builder_version" => @builder_version
      }
      |> Portal.Workers.HostNativeBuild.new(queue: queue)
      |> Oban.insert()
    end
  end

  defp queue_of(triple) do
    case queue(triple) do
      {:ok, queue} -> {:ok, queue}
      :error -> {:error, :unknown_triple}
    end
  end

  defp toolchain(nil) do
    case Portal.Toolchains.images() do
      [%{toolchain: toolchain} | _] -> {:ok, toolchain}
      _ -> {:error, :unknown_toolchain}
    end
  end

  defp toolchain(name) do
    if Enum.any?(Portal.Toolchains.images(), &(&1.toolchain == name)),
      do: {:ok, name},
      else: {:error, :unknown_toolchain}
  end

  @doc """
  The served host-native builds of a package (by id and name): none while
  the setting is off.
  """
  @spec served(Ecto.UUID.t(), String.t(), [String.t()]) :: [HostNativeBuild.t()]
  def served(package_id, package_name, withheld \\ Withheld.packages()) do
    if enabled?() do
      HostNativeBuild
      |> Ash.Query.filter(package_id == ^package_id and status == :pass and is_nil(revoked_at))
      |> Ash.read!(domain: Portal.Catalog)
      |> Enum.reject(&withheld?(&1, package_name, withheld))
      |> reject_plugin_withheld()
    else
      []
    end
  end

  # A build whose run ran a watched rebar3 plugin release
  # (`Portal.Precompiled.PluginWatch`).
  defp reject_plugin_withheld(builds) do
    withheld = Portal.Precompiled.PluginWatch.withheld_runs(Enum.map(builds, & &1.run_id))
    Enum.reject(builds, &MapSet.member?(withheld, &1.run_id))
  end

  # Every host-native build records its config reads in the write that
  # records its run (`Portal.HostNative.Ingest`).
  defp withheld?(build, package_name, withheld) do
    Withheld.withheld?(package_name, build.deps_lock, withheld, %{
      compile_env_rule: build.compile_env_rule,
      compile_env: build.compile_env,
      run_id: build.run_id,
      compile_env_run_id: build.run_id
    })
  end

  @doc "The stored file shas of each build, by build id."
  @spec membership_shas([Ecto.UUID.t()]) :: %{Ecto.UUID.t() => MapSet.t()}
  def membership_shas([]), do: %{}

  def membership_shas(ids) do
    ArtifactMembership
    |> Ash.Query.filter(host_native_build_id in ^ids)
    |> Ash.Query.select([:host_native_build_id, :sha256])
    |> Ash.read!(domain: Portal.Catalog)
    |> Enum.group_by(& &1.host_native_build_id, & &1.sha256)
    |> Map.new(fn {id, shas} -> {id, MapSet.new(shas)} end)
  end

  @doc "Every sha a file manifest (`%{\"ebin\" => [...], \"priv\" => [...]}`) lists."
  @spec manifest_shas(term()) :: [String.t()]
  def manifest_shas(%{} = manifest) do
    for key <- ["ebin", "priv"],
        entries = Map.get(manifest, key),
        is_list(entries),
        %{"sha256" => sha} <- entries,
        is_binary(sha),
        do: sha
  end

  def manifest_shas(_manifest), do: []

  @doc false
  # The package row of a name, for the build worker's failure rows.
  @spec package_id(String.t()) :: Ecto.UUID.t() | nil
  def package_id(name) do
    case Package |> Ash.Query.filter(name == ^name) |> Ash.read!(domain: Portal.Catalog) do
      [package] -> package.id
      _ -> nil
    end
  end
end
